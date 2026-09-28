$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Engine = Join-Path $Here 'Skate3-PS3-to-X360-Map-Importer.ps1'
$Installer = Join-Path $Here 'Install-Converted-Map-To-Recomp.ps1'
$Worker = Join-Path $Here 'Skate3-PS3-to-X360-Map-Importer-GUI-Worker.ps1'
$DlcManager = Join-Path $Here 'Manage-Installed-DLC-Maps.ps1'
$GuiVersion = '1.16'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

public sealed class GuiProcessRunner : IDisposable
{
    private readonly ConcurrentQueue<string> lines = new ConcurrentQueue<string>();
    private Process process;

    public int ProcessId { get { return process == null ? 0 : process.Id; } }
    public bool IsRunning { get { return process != null && !process.HasExited; } }
    public bool HasExited { get { return process != null && process.HasExited; } }
    public int ExitCode { get { return (process != null && process.HasExited) ? process.ExitCode : -99999; } }

    public void Start(string fileName, string arguments, string workingDirectory)
    {
        if (process != null) throw new InvalidOperationException("A process is already assigned.");
        var psi = new ProcessStartInfo();
        psi.FileName = fileName;
        psi.Arguments = arguments;
        psi.WorkingDirectory = workingDirectory;
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;

        process = new Process();
        process.StartInfo = psi;
        process.EnableRaisingEvents = true;
        process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
            if (e.Data != null) lines.Enqueue(e.Data);
        };
        process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) {
            if (e.Data != null) lines.Enqueue(e.Data);
        };
        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }

    public string[] DrainLines()
    {
        var list = new System.Collections.Generic.List<string>();
        string line;
        while (lines.TryDequeue(out line)) list.Add(line);
        return list.ToArray();
    }

    public void Dispose()
    {
        if (process != null) process.Dispose();
        process = null;
    }
}
"@

function New-Label([string]$Text, [int]$X, [int]$Y, [int]$W = 145, [int]$H = 24) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $Text
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    $c.ForeColor = [System.Drawing.Color]::Gainsboro
    $c.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    return $c
}

function New-TextBox([int]$X, [int]$Y, [int]$W, [string]$Text = '') {
    $c = New-Object System.Windows.Forms.TextBox
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, 25)
    $c.Text = $Text
    $c.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $c.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
    $c.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $c.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    return $c
}

function New-Button([string]$Text, [int]$X, [int]$Y, [int]$W = 110, [int]$H = 30) {
    $c = New-Object System.Windows.Forms.Button
    $c.Text = $Text
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    $c.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $c.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(90,90,95)
    $c.BackColor = [System.Drawing.Color]::FromArgb(60,60,64)
    $c.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $c.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
    return $c
}

function New-NumberBox([int]$X, [int]$Y, [decimal]$Value) {
    $c = New-Object System.Windows.Forms.NumericUpDown
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size(95, 25)
    $c.DecimalPlaces = 2
    $c.Minimum = -1000000
    $c.Maximum = 1000000
    $c.Increment = 1
    $c.Value = $Value
    $c.BackColor = [System.Drawing.Color]::FromArgb(45,45,48)
    $c.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $c.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $c.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    return $c
}

function Quote-PS([string]$Text) {
    return "'" + ($Text -replace "'", "''") + "'"
}

function Make-Slug([string]$Text) {
    $s = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', '_'
    $s = $s.Trim('_')
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'custom_map' }
    if ($s.Length -gt 40) { $s = $s.Substring(0,40).TrimEnd('_') }
    return $s
}

function Guess-DisplayName([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $leaf = Split-Path -Leaf $Path
    if ([System.IO.File]::Exists($Path)) { $leaf = [System.IO.Path]::GetFileNameWithoutExtension($leaf) }
    $leaf = $leaf -replace '^DIST_', ''
    $leaf = $leaf -replace '[_\-]+', ' '
    return $leaf.Trim()
}

function Select-SourceArchive {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Select PS3 Skate 3 map archive'
    $dlg.Filter = 'Map archives (*.rar;*.zip;*.7z)|*.rar;*.zip;*.7z|All files (*.*)|*.*'
    $dlg.CheckFileExists = $true
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return ''
}

function Select-Folder([string]$Description, [bool]$NewFolder = $true) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $NewFolder
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return ''
}

function Test-GroupModeEnabled {
    return ($chkGroup.CheckState -eq [System.Windows.Forms.CheckState]::Checked)
}

function Sync-GroupUi {
    $on = Test-GroupModeEnabled

    # Keep the text box usable whenever the GUI is idle. v1.06 tied its Enabled
    # property directly to a single CheckedChanged callback; on some Windows
    # PowerShell/WinForms setups that callback did not refresh the rest of the UI.
    # The checkbox now controls whether the value is USED, not whether it can be edited.
    $txtGroup.Enabled = -not $script:IsRunning

    if ($on -and [string]::IsNullOrWhiteSpace($txtGroup.Text)) {
        $txtGroup.Text = 'Custom Maps'
    }

    if ($on) {
        $chkGroup.Text = 'Parent grouping ENABLED'
        $chkGroup.ForeColor = [System.Drawing.Color]::FromArgb(120,220,150)
    } else {
        $chkGroup.Text = 'Store this map under a parent Location / District'
        $chkGroup.ForeColor = [System.Drawing.Color]::WhiteSmoke
    }

    Update-GroupPreview
}

function Set-RunningState([bool]$Running) {
    $script:IsRunning = $Running
    $btnArchive.Enabled = -not $Running
    $btnDistFolder.Enabled = -not $Running
    $btnOutput.Enabled = -not $Running
    $btnRecomp.Enabled = (-not $Running) -and $chkInstall.Checked
    $txtSource.Enabled = -not $Running
    $txtName.Enabled = -not $Running
    $txtDist.Enabled = -not $Running
    $txtOutput.Enabled = -not $Running
    $txtRecomp.Enabled = (-not $Running) -and $chkInstall.Checked
    $numX.Enabled = -not $Running
    $numY.Enabled = -not $Running
    $numZ.Enabled = -not $Running
    $numYaw.Enabled = -not $Running
    $chkInstall.Enabled = -not $Running
    $chkGroup.Enabled = -not $Running
    $txtGroup.Enabled = -not $Running
    $btnGroupManager.Enabled = -not $Running
    $chkRefresh.Enabled = -not $Running
    $chkStaging.Enabled = -not $Running
    $chkLightmaps.Enabled = -not $Running
    $chkMacroOverlay.Enabled = -not $Running
    $chkBypassLightmap.Enabled = $false
    $btnStart.Enabled = -not $Running
    $btnCancel.Enabled = $Running
    $btnInstallExisting.Enabled = -not $Running
    $btnDlcManager.Enabled = -not $Running
    $progress.Visible = $Running
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
}

function Append-Log([string]$Line) {
    if ($null -eq $Line) { return }
    $txtLog.AppendText($Line + [Environment]::NewLine)
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()

    if ($Line -match 'Preparing pinned') { $lblStatus.Text = 'Status: Preparing conversion toolchain...' }
    elseif ($Line -match 'Converting PS3 map to Xbox 360') { $lblStatus.Text = 'Status: Rebuilding PS3 map for Xbox 360...' }
    elseif ($Line -match 'Validating converted Xbox') { $lblStatus.Text = 'Status: Validating Xbox 360 meshes...' }
    elseif ($Line -match 'Rebuilding Location Group') { $lblStatus.Text = 'Status: Rebuilding grouped Locations package...' }
    elseif ($Line -match 'Packing grouped Xbox 360 DLC') { $lblStatus.Text = 'Status: Packing grouped Xbox 360 DLC...' }
    elseif ($Line -match 'Packing Xbox 360 DLC') { $lblStatus.Text = 'Status: Packing Xbox 360 DLC...' }
    elseif ($Line -match 'Installed to Skate3Recomp') { $lblStatus.Text = 'Status: Installing into Skate3Recomp...' }
    elseif ($Line -match 'CONVERSION COMPLETE') { $lblStatus.Text = 'Status: Conversion complete.' }
}


function Get-LocationGroupInfo([string]$OutputRootPath, [string]$GroupDisplayName) {
    if ([string]::IsNullOrWhiteSpace($OutputRootPath) -or [string]::IsNullOrWhiteSpace($GroupDisplayName)) { return $null }
    try {
        $root = [System.IO.Path]::GetFullPath($OutputRootPath.Trim().Trim('"'))
        $slug = Make-Slug $GroupDisplayName
        $groupRoot = Join-Path $root ("Location-Groups\" + $slug)
        $project = Join-Path $groupRoot 'location-group.json'
        if (-not (Test-Path -LiteralPath $project)) {
            return [PSCustomObject]@{ Root=$groupRoot; ProjectPath=$project; GroupName=$GroupDisplayName; Count=0; Maps=@() }
        }
        $cfg = Get-Content -LiteralPath $project -Raw | ConvertFrom-Json
        $maps = @()
        if ($cfg.Maps) { $maps = @($cfg.Maps) }
        $name = if ($cfg.GroupName) { [string]$cfg.GroupName } else { $GroupDisplayName }
        return [PSCustomObject]@{ Root=$groupRoot; ProjectPath=$project; GroupName=$name; Count=$maps.Count; Maps=$maps }
    } catch { return $null }
}

function Update-GroupPreview {
    if (-not (Test-GroupModeEnabled)) {
        $lblGroupPreview.Text = 'Grouping off: this map will be its own top-level Locations entry.'
        return
    }
    $name = $txtGroup.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        $lblGroupPreview.Text = 'Enter a parent name, e.g. Community Maps.'
        return
    }
    $info = Get-LocationGroupInfo $txtOutput.Text $name
    $saved = if ($info) { [int]$info.Count } else { 0 }
    $pendingName = $txtName.Text.Trim()
    $already = $false
    if ($info -and -not [string]::IsNullOrWhiteSpace($pendingName)) {
        $already = [bool](@($info.Maps | Where-Object { [string]$_.DisplayName -ieq $pendingName }).Count)
    }
    $expected = $saved
    if (-not [string]::IsNullOrWhiteSpace($pendingName) -and -not $already) { $expected++ }
    if ($expected -lt 1) { $expected = 1 }
    $lblGroupPreview.Text = ('In game: {0} ({1})  ->  click once to open {1} child map location(s)' -f $name, $expected)
}

function Show-LocationGroupManager {
    $outputRoot = $txtOutput.Text.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($outputRoot)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Choose an Output root first.', 'Output root required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $groupsRoot = Join-Path $outputRoot 'Location-Groups'

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Location / District Groups'
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.Size = New-Object System.Drawing.Size(760, 510)
    $dlg.MinimumSize = New-Object System.Drawing.Size(700, 460)
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(30,30,32)
    $dlg.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $head = New-Object System.Windows.Forms.Label
    $head.Text = 'Stock-style parent Locations'
    $head.Location = New-Object System.Drawing.Point(16, 14)
    $head.Size = New-Object System.Drawing.Size(360, 28)
    $head.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 14)
    $dlg.Controls.Add($head)

    $desc = New-Object System.Windows.Forms.Label
    $desc.Text = 'Each parent appears as Name (count). Selecting it opens the child maps listed on the right.'
    $desc.Location = New-Object System.Drawing.Point(18, 45)
    $desc.Size = New-Object System.Drawing.Size(700, 22)
    $desc.ForeColor = [System.Drawing.Color]::Silver
    $dlg.Controls.Add($desc)

    $lstGroups = New-Object System.Windows.Forms.ListBox
    $lstGroups.Location = New-Object System.Drawing.Point(18, 78)
    $lstGroups.Size = New-Object System.Drawing.Size(300, 320)
    $lstGroups.BackColor = [System.Drawing.Color]::FromArgb(42,42,45)
    $lstGroups.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $dlg.Controls.Add($lstGroups)

    $lstMaps = New-Object System.Windows.Forms.ListBox
    $lstMaps.Location = New-Object System.Drawing.Point(335, 78)
    $lstMaps.Size = New-Object System.Drawing.Size(385, 320)
    $lstMaps.BackColor = [System.Drawing.Color]::FromArgb(42,42,45)
    $lstMaps.ForeColor = [System.Drawing.Color]::WhiteSmoke
    $dlg.Controls.Add($lstMaps)

    $groupObjects = @()
    if (Test-Path -LiteralPath $groupsRoot) {
        foreach ($file in Get-ChildItem -LiteralPath $groupsRoot -Filter 'location-group.json' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName) {
            try {
                $cfg = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                $maps = if ($cfg.Maps) { @($cfg.Maps) } else { @() }
                $name = if ($cfg.GroupName) { [string]$cfg.GroupName } else { Split-Path -Leaf $file.DirectoryName }
                $obj = [PSCustomObject]@{ Name=$name; Count=$maps.Count; Maps=$maps; Root=$file.DirectoryName }
                $groupObjects += $obj
                [void]$lstGroups.Items.Add(('{0} ({1})' -f $name, $maps.Count))
            } catch {}
        }
    }

    $refreshMaps = {
        $lstMaps.Items.Clear()
        $i = $lstGroups.SelectedIndex
        if ($i -lt 0 -or $i -ge $groupObjects.Count) { return }
        foreach ($m in @($groupObjects[$i].Maps)) {
            [void]$lstMaps.Items.Add([string]$m.DisplayName)
        }
    }
    $lstGroups.Add_SelectedIndexChanged($refreshMaps)
    if ($lstGroups.Items.Count -gt 0) { $lstGroups.SelectedIndex = 0 }

    $btnUse = New-Button 'Use Selected Parent' 18 414 150 32
    $btnUse.Add_Click({
        $i = $lstGroups.SelectedIndex
        if ($i -ge 0 -and $i -lt $groupObjects.Count) {
            $txtGroup.Text = [string]$groupObjects[$i].Name
            $chkGroup.CheckState = [System.Windows.Forms.CheckState]::Checked
            Sync-GroupUi
            $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dlg.Close()
        }
    })
    $dlg.Controls.Add($btnUse)

    $btnOpen = New-Button 'Open Group Folder' 178 414 145 32
    $btnOpen.Add_Click({
        $i = $lstGroups.SelectedIndex
        if ($i -ge 0 -and $i -lt $groupObjects.Count -and (Test-Path -LiteralPath $groupObjects[$i].Root)) {
            Start-Process explorer.exe -ArgumentList @($groupObjects[$i].Root)
        }
    })
    $dlg.Controls.Add($btnOpen)

    $btnClose = New-Button 'Close' 610 414 110 32
    $btnClose.Add_Click({ $dlg.Close() })
    $dlg.Controls.Add($btnClose)

    if ($groupObjects.Count -eq 0) {
        [void]$lstGroups.Items.Add('(no saved parent groups yet)')
        $btnUse.Enabled = $false
        $btnOpen.Enabled = $false
    }

    [void]$dlg.ShowDialog($form)
}

function Save-GuiSettings {
    try {
        $settingsDir = Join-Path $env:LOCALAPPDATA 'Skate3PS3ToX360MapImporter'
        New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
        [PSCustomObject]@{
            OutputRoot = $txtOutput.Text
            RecompDir = $txtRecomp.Text
            InstallToRecomp = $chkInstall.Checked
            KeepStaging = $chkStaging.Checked
            GroupEnabled = (Test-GroupModeEnabled)
            GroupName = $txtGroup.Text
            NeutralizeLightmaps = [bool]$chkLightmaps.Checked
            SuppressMacroOverlay = [bool]$chkMacroOverlay.Checked
            BypassBakedLightmaps = $false
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $settingsDir 'gui-settings.json') -Encoding UTF8
    } catch {}
}

function Load-GuiSettings {
    $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
    $txtOutput.Text = Join-Path $documents 'Skate3-X360-Converted-Maps'
    try {
        $path = Join-Path $env:LOCALAPPDATA 'Skate3PS3ToX360MapImporter\gui-settings.json'
        if (Test-Path $path) {
            $s = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if ($s.OutputRoot) { $txtOutput.Text = [string]$s.OutputRoot }
            if ($s.RecompDir) { $txtRecomp.Text = [string]$s.RecompDir }
            $chkInstall.Checked = [bool]$s.InstallToRecomp
            $chkStaging.Checked = [bool]$s.KeepStaging
            if ($null -ne $s.GroupEnabled) { $chkGroup.CheckState = if ([bool]$s.GroupEnabled) { [System.Windows.Forms.CheckState]::Checked } else { [System.Windows.Forms.CheckState]::Unchecked } }
            if ($s.GroupName) { $txtGroup.Text = [string]$s.GroupName }
            if ($null -ne $s.NeutralizeLightmaps) { $chkLightmaps.Checked = [bool]$s.NeutralizeLightmaps }
            if ($null -ne $s.SuppressMacroOverlay) { $chkMacroOverlay.Checked = [bool]$s.SuppressMacroOverlay }
            $chkBypassLightmap.Checked = $false
        }
    } catch {}
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Skate 3 PS3 -> Xbox 360 Map Importer v$GuiVersion"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Size = New-Object System.Drawing.Size(1040, 995)
$form.MinimumSize = New-Object System.Drawing.Size(900, 920)
$form.BackColor = [System.Drawing.Color]::FromArgb(30,30,32)
$form.ForeColor = [System.Drawing.Color]::WhiteSmoke
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.AllowDrop = $true

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Skate 3  |  PS3 -> Xbox 360 Map Importer'
$title.Location = New-Object System.Drawing.Point(20, 15)
$title.Size = New-Object System.Drawing.Size(760, 32)
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$title.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Convert PS3 DIST maps into Xbox 360-native Skate 3 maps, including recursive archives, texture compatibility fixes, and stock-style parent/child Locations groups.'
$subtitle.Location = New-Object System.Drawing.Point(22, 49)
$subtitle.Size = New-Object System.Drawing.Size(920, 22)
$subtitle.ForeColor = [System.Drawing.Color]::Silver
$form.Controls.Add($subtitle)

$grpInput = New-Object System.Windows.Forms.GroupBox
$grpInput.Text = 'PS3 Map'
$grpInput.Location = New-Object System.Drawing.Point(20, 80)
$grpInput.Size = New-Object System.Drawing.Size(990, 150)
$grpInput.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($grpInput)

$grpInput.Controls.Add((New-Label 'Source archive / DIST folder' 15 31 170))
$txtSource = New-TextBox 185 28 555
$grpInput.Controls.Add($txtSource)
$btnArchive = New-Button 'Browse Archive...' 750 25 110 30
$grpInput.Controls.Add($btnArchive)
$btnDistFolder = New-Button 'Browse Folder...' 865 25 110 30
$grpInput.Controls.Add($btnDistFolder)

$grpInput.Controls.Add((New-Label 'Location display name' 15 72 170))
$txtName = New-TextBox 185 69 340
$grpInput.Controls.Add($txtName)
$grpInput.Controls.Add((New-Label 'Source DIST (if multiple)' 545 72 165))
$txtDist = New-TextBox 710 69 265
$grpInput.Controls.Add($txtDist)

$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Tip: drag a .rar/.zip/.7z or DIST_* folder anywhere onto this window.'
$hint.Location = New-Object System.Drawing.Point(185, 107)
$hint.Size = New-Object System.Drawing.Size(620, 22)
$hint.ForeColor = [System.Drawing.Color]::DarkGray
$grpInput.Controls.Add($hint)

$grpGroup = New-Object System.Windows.Forms.GroupBox
$grpGroup.Text = 'District / Parent Location Grouping (stock-style)'
$grpGroup.Location = New-Object System.Drawing.Point(20, 240)
$grpGroup.Size = New-Object System.Drawing.Size(990, 125)
$grpGroup.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($grpGroup)

$chkGroup = New-Object System.Windows.Forms.CheckBox
$chkGroup.Text = 'Store this map under a parent Location / District'
$chkGroup.Location = New-Object System.Drawing.Point(15, 28)
$chkGroup.Size = New-Object System.Drawing.Size(340, 25)
$chkGroup.ForeColor = [System.Drawing.Color]::WhiteSmoke
$grpGroup.Controls.Add($chkGroup)

$grpGroup.Controls.Add((New-Label 'Parent name' 370 31 85))
$txtGroup = New-TextBox 455 28 250 'Custom Maps'
$txtGroup.Enabled = $true
$grpGroup.Controls.Add($txtGroup)

$btnGroupManager = New-Button 'View Saved Parents...' 720 25 155 30
$grpGroup.Controls.Add($btnGroupManager)

$groupHint = New-Object System.Windows.Forms.Label
$groupHint.Text = 'Use the same parent name for several conversions. One parent is rebuilt with one child freeskate row per independent DIST_* map.'
$groupHint.Location = New-Object System.Drawing.Point(15, 58)
$groupHint.Size = New-Object System.Drawing.Size(950, 20)
$groupHint.ForeColor = [System.Drawing.Color]::DarkGray
$grpGroup.Controls.Add($groupHint)

$lblGroupPreview = New-Object System.Windows.Forms.Label
$lblGroupPreview.Text = 'Grouping off: this map will be its own top-level Locations entry.'
$lblGroupPreview.Location = New-Object System.Drawing.Point(15, 84)
$lblGroupPreview.Size = New-Object System.Drawing.Size(950, 24)
$lblGroupPreview.ForeColor = [System.Drawing.Color]::FromArgb(130,190,230)
$lblGroupPreview.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
$grpGroup.Controls.Add($lblGroupPreview)

$grpOptions = New-Object System.Windows.Forms.GroupBox
$grpOptions.Text = 'Xbox 360 Conversion'
$grpOptions.Location = New-Object System.Drawing.Point(20, 375)
$grpOptions.Size = New-Object System.Drawing.Size(990, 265)
$grpOptions.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($grpOptions)

$grpOptions.Controls.Add((New-Label 'Output root' 15 31 110))
$txtOutput = New-TextBox 125 28 715
$grpOptions.Controls.Add($txtOutput)
$btnOutput = New-Button 'Browse...' 850 25 125 30
$grpOptions.Controls.Add($btnOutput)

$grpOptions.Controls.Add((New-Label 'Spawn X' 15 74 60))
$numX = New-NumberBox 75 70 0
$grpOptions.Controls.Add($numX)
$grpOptions.Controls.Add((New-Label 'Y' 180 74 20))
$numY = New-NumberBox 205 70 30
$grpOptions.Controls.Add($numY)
$grpOptions.Controls.Add((New-Label 'Z' 310 74 20))
$numZ = New-NumberBox 335 70 0
$grpOptions.Controls.Add($numZ)
$grpOptions.Controls.Add((New-Label 'Yaw' 440 74 40))
$numYaw = New-NumberBox 485 70 0
$grpOptions.Controls.Add($numYaw)

$chkInstall = New-Object System.Windows.Forms.CheckBox
$chkInstall.Text = 'Install finished Xbox 360 DLC into Skate3Recomp'
$chkInstall.Location = New-Object System.Drawing.Point(15, 112)
$chkInstall.Size = New-Object System.Drawing.Size(330, 25)
$chkInstall.ForeColor = [System.Drawing.Color]::WhiteSmoke
$grpOptions.Controls.Add($chkInstall)

$txtRecomp = New-TextBox 355 110 485
$grpOptions.Controls.Add($txtRecomp)
$btnRecomp = New-Button 'Browse Recomp...' 850 107 125 30
$grpOptions.Controls.Add($btnRecomp)

$chkRefresh = New-Object System.Windows.Forms.CheckBox
$chkRefresh.Text = 'Force toolchain refresh / rebuild'
$chkRefresh.Location = New-Object System.Drawing.Point(15, 155)
$chkRefresh.Size = New-Object System.Drawing.Size(240, 25)
$chkRefresh.ForeColor = [System.Drawing.Color]::Gainsboro
$grpOptions.Controls.Add($chkRefresh)

$chkStaging = New-Object System.Windows.Forms.CheckBox
$chkStaging.Text = 'Keep X360 DLC staging folder'
$chkStaging.Location = New-Object System.Drawing.Point(275, 155)
$chkStaging.Size = New-Object System.Drawing.Size(230, 25)
$chkStaging.ForeColor = [System.Drawing.Color]::Gainsboro
$grpOptions.Controls.Add($chkStaging)

$chkLightmaps = New-Object System.Windows.Forms.CheckBox
$chkLightmaps.Text = 'Fix wrong/repeated baked-light texture (selective referenced lightmaps only)'
$chkLightmaps.Location = New-Object System.Drawing.Point(520, 155)
$chkLightmaps.Size = New-Object System.Drawing.Size(470, 25)
$chkLightmaps.ForeColor = [System.Drawing.Color]::FromArgb(130,190,230)
$chkLightmaps.Checked = $false
$chkLightmaps.Enabled = $true
$grpOptions.Controls.Add($chkLightmaps)

$chkMacroOverlay = New-Object System.Windows.Forms.CheckBox
$chkMacroOverlay.Text = 'Fix repeating rock/wood overlay (disable macro-overlay; preserves diffuse)'
$chkMacroOverlay.Location = New-Object System.Drawing.Point(15, 184)
$chkMacroOverlay.Size = New-Object System.Drawing.Size(620, 25)
$chkMacroOverlay.ForeColor = [System.Drawing.Color]::FromArgb(245,190,110)
$chkMacroOverlay.Checked = $false
$chkMacroOverlay.Enabled = $true
$grpOptions.Controls.Add($chkMacroOverlay)

$chkBypassLightmap = New-Object System.Windows.Forms.CheckBox
$chkBypassLightmap.Text = 'Legacy stock-white lightmap binding bypass (unsafe; disabled in v1.16)'
$chkBypassLightmap.Location = New-Object System.Drawing.Point(15, 213)
$chkBypassLightmap.Size = New-Object System.Drawing.Size(650, 25)
$chkBypassLightmap.ForeColor = [System.Drawing.Color]::FromArgb(140,140,140)
$chkBypassLightmap.Checked = $false
$chkBypassLightmap.Enabled = $false
$grpOptions.Controls.Add($chkBypassLightmap)

$fixes = New-Object System.Windows.Forms.Label
$fixes.Text = 'Always enabled: full vertex rebuild  |  RenderModel bounds  |  FLOAT2/stride32 UV  |  X360 material GUID remap  |  validation  |  EA BIG'
$fixes.Location = New-Object System.Drawing.Point(15, 240)
$fixes.Size = New-Object System.Drawing.Size(950, 18)
$fixes.ForeColor = [System.Drawing.Color]::FromArgb(130,190,230)
$grpOptions.Controls.Add($fixes)

$btnStart = New-Button 'CONVERT PS3 -> X360' 20 655 190 38
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(0,105,160)
$btnStart.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(30,150,210)
$form.Controls.Add($btnStart)

$btnCancel = New-Button 'Cancel' 220 655 100 38
$btnCancel.Enabled = $false
$form.Controls.Add($btnCancel)

$btnOpenOutput = New-Button 'Open Output' 330 655 115 38
$btnOpenOutput.Enabled = $false
$form.Controls.Add($btnOpenOutput)

$btnInstallExisting = New-Button 'Install Existing Conversion...' 455 655 190 38
$form.Controls.Add($btnInstallExisting)

$btnDlcManager = New-Button 'Manage / Remove DLC Maps...' 655 655 185 38
$btnDlcManager.BackColor = [System.Drawing.Color]::FromArgb(85,65,45)
$form.Controls.Add($btnDlcManager)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Status: Ready.'
$lblStatus.Location = New-Object System.Drawing.Point(845, 660)
$lblStatus.Size = New-Object System.Drawing.Size(160, 24)
$lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblStatus.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($lblStatus)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(20, 700)
$progress.Size = New-Object System.Drawing.Size(990, 10)
$progress.MarqueeAnimationSpeed = 25
$progress.Visible = $false
$form.Controls.Add($progress)

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 722)
$txtLog.Size = New-Object System.Drawing.Size(990, 220)
$txtLog.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(18,18,20)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220,220,220)
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($txtLog)

$script:Runner = $null
$script:OutputFolder = ''
$script:CancelRequested = $false
$script:IsRunning = $false
$script:LastGroupCheckState = [System.Windows.Forms.CheckState]::Indeterminate

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150
$timer.Add_Tick({
    if ($null -eq $script:Runner) { return }
    foreach ($line in $script:Runner.DrainLines()) { Append-Log $line }

    if ($script:Runner.HasExited) {
        foreach ($line in $script:Runner.DrainLines()) { Append-Log $line }
        $code = $script:Runner.ExitCode
        $timer.Stop()
        $script:Runner.Dispose()
        $script:Runner = $null
        Set-RunningState $false

        if ($script:CancelRequested) {
            $lblStatus.Text = 'Status: Cancelled.'
            Append-Log '--- Conversion cancelled by user. ---'
        } elseif ($code -eq 0) {
            $lblStatus.Text = 'Status: Complete.'
            $btnOpenOutput.Enabled = (Test-Path $script:OutputFolder)
            Update-GroupPreview
            Append-Log '--- GUI: conversion finished successfully. ---'
            [System.Media.SystemSounds]::Asterisk.Play()
        } else {
            $lblStatus.Text = "Status: Failed (exit code $code)."
            Append-Log "--- GUI: converter exited with error code $code. ---"
            [System.Media.SystemSounds]::Hand.Play()
            [System.Windows.Forms.MessageBox]::Show($form, "The converter exited with error code $code.`r`n`r`nSee the log pane for the last error.", 'Conversion failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
})

# Safety-net UI poller. This fixes the exact v1.06 symptom where the checkbox could
# visibly change but Parent name/preview stayed in the old state.
$groupStateTimer = New-Object System.Windows.Forms.Timer
$groupStateTimer.Interval = 200
$groupStateTimer.Add_Tick({
    $state = $chkGroup.CheckState
    $expectedEnabled = -not $script:IsRunning
    if ($state -ne $script:LastGroupCheckState -or $txtGroup.Enabled -ne $expectedEnabled) {
        $script:LastGroupCheckState = $state
        Sync-GroupUi
    }
})
$groupStateTimer.Start()

$btnArchive.Add_Click({
    $p = Select-SourceArchive
    if ($p) {
        $txtSource.Text = $p
        if ([string]::IsNullOrWhiteSpace($txtName.Text)) { $txtName.Text = Guess-DisplayName $p }
    }
})

$btnDistFolder.Add_Click({
    $p = Select-Folder 'Select an extracted PS3 DIST_* map folder (or a parent containing one)' $false
    if ($p) {
        $txtSource.Text = $p
        if ([string]::IsNullOrWhiteSpace($txtName.Text)) { $txtName.Text = Guess-DisplayName $p }
    }
})

$btnOutput.Add_Click({
    $p = Select-Folder 'Select output root for converted Xbox 360 maps' $true
    if ($p) { $txtOutput.Text = $p }
})

$btnRecomp.Add_Click({
    $p = Select-Folder 'Select Skate3Recomp folder containing skate3.exe' $false
    if ($p) { $txtRecomp.Text = $p }
})

$chkInstall.Add_CheckedChanged({
    $txtRecomp.Enabled = $chkInstall.Checked -and $btnStart.Enabled
    $btnRecomp.Enabled = $chkInstall.Checked -and $btnStart.Enabled
})

# Redundant WinForms hooks are intentional. Some Windows PowerShell builds failed
# to refresh v1.06's group state from CheckedChanged alone. Any checkbox interaction
# now re-synchronizes the controls, and a lightweight state timer below acts as a
# final safety net.
$chkGroup.Add_CheckedChanged({ Sync-GroupUi })
$chkGroup.Add_CheckStateChanged({ Sync-GroupUi })
$chkGroup.Add_Click({ Sync-GroupUi })
$chkGroup.Add_MouseUp({ Sync-GroupUi })
$txtGroup.Add_TextChanged({ Update-GroupPreview })
$txtOutput.Add_TextChanged({ Update-GroupPreview })
$txtName.Add_TextChanged({ Update-GroupPreview })
$btnGroupManager.Add_Click({ Show-LocationGroupManager })

$form.Add_DragEnter({
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $_.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$form.Add_DragDrop({
    $items = [string[]]$_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop)
    if ($items -and $items.Count -gt 0) {
        $txtSource.Text = $items[0]
        if ([string]::IsNullOrWhiteSpace($txtName.Text)) { $txtName.Text = Guess-DisplayName $items[0] }
    }
})

$btnStart.Add_Click({
    if (-not (Test-Path $Engine)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Importer engine is missing from this folder.', 'Missing file', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $source = $txtSource.Text.Trim().Trim('"')
    $name = $txtName.Text.Trim()
    $output = $txtOutput.Text.Trim().Trim('"')
    $dist = $txtDist.Text.Trim()
    $recomp = $txtRecomp.Text.Trim().Trim('"')
    $groupEnabled = Test-GroupModeEnabled
    $groupName = if ($groupEnabled) { $txtGroup.Text.Trim() } else { '' }

    if ([string]::IsNullOrWhiteSpace($source) -or -not (Test-Path $source)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Choose a valid PS3 map archive or DIST folder.', 'Source required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = Guess-DisplayName $source
        $txtName.Text = $name
    }
    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Enter a location display name.', 'Name required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($output)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Choose an output root folder.', 'Output required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($groupEnabled -and [string]::IsNullOrWhiteSpace($groupName)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Enter a Location Group name, or turn grouping off.', 'Group name required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($chkInstall.Checked) {
        if ([string]::IsNullOrWhiteSpace($recomp) -or -not (Test-Path (Join-Path $recomp 'skate3.exe'))) {
            [System.Windows.Forms.MessageBox]::Show($form, 'Choose the Skate3Recomp folder that contains skate3.exe.', 'Recomp folder required', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
    }

    try { New-Item -ItemType Directory -Force -Path $output | Out-Null } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "Could not create/access the output folder:`r`n$output", 'Output error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    Save-GuiSettings
    $txtLog.Clear()
    Append-Log "Skate 3 PS3 -> Xbox 360 Map Importer GUI v$GuiVersion"
    Append-Log "Source: $source"
    Append-Log "Name:   $name"
    Append-Log ("Parent grouping: " + $(if ($groupEnabled) { 'ENABLED' } else { 'OFF' }))
    if ($groupEnabled) { Append-Log "Parent/District: $groupName" }
    Append-Log "Spawn:  $($numX.Value),$($numY.Value),$($numZ.Value),$($numYaw.Value)"
    Append-Log ("Texture mode: " + $(if ($chkLightmaps.Checked) { "SELECTIVE referenced-lightmap repair ON (bindings/alpha/masks preserved)" } else { "lossless authored payloads; selective repair OFF" }))
    Append-Log ("Material overlay repair: " + $(if ($chkMacroOverlay.Checked) { "ON - macroOverlayOpacity forced to 0" } else { "OFF" }))
    Append-Log 'Legacy stock-white binding bypass: DISABLED in v1.16'
    Append-Log ''

    $slug = Make-Slug $name
    if ($groupEnabled) {
        $script:OutputFolder = Join-Path ([System.IO.Path]::GetFullPath($output)) ("Location-Groups\" + (Make-Slug $groupName))
    } else {
        $script:OutputFolder = Join-Path ([System.IO.Path]::GetFullPath($output)) $slug
    }
    $script:CancelRequested = $false

    if (-not (Test-Path $Worker)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'GUI worker is missing from this folder.', 'Missing file', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $jobDir = Join-Path $env:TEMP 'Skate3PS3ToX360MapImporter-GUI'
    New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
    $jobPath = Join-Path $jobDir (([Guid]::NewGuid().ToString('N')) + '.json')
    [PSCustomObject]@{
        SourcePath = $source
        OutputRoot = $output
        DisplayName = $name
        DistName = $dist
        GroupEnabled = [bool]$groupEnabled
        GroupName = $groupName
        NeutralizeLightmaps = [bool]$chkLightmaps.Checked
        SuppressMacroOverlay = [bool]$chkMacroOverlay.Checked
        BypassBakedLightmaps = $false
        SpawnX = [double]$numX.Value
        SpawnY = [double]$numY.Value
        SpawnZ = [double]$numZ.Value
        SpawnYaw = [double]$numYaw.Value
        InstallToRecomp = [bool]$chkInstall.Checked
        RecompDir = $recomp
        ForceToolchainRefresh = [bool]$chkRefresh.Checked
        KeepStaging = [bool]$chkStaging.Checked
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $jobPath -Encoding UTF8

    # -File + a one-argument JSON job avoids EncodedCommand/CLIXML output and avoids
    # fragile quoting of every user-selected map path.
    $workerArg = '"' + ($Worker -replace '"','\\"') + '"'
    $jobArg = '"' + ($jobPath -replace '"','\\"') + '"'
    $args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + $workerArg + ' -ConfigPath ' + $jobArg

    try {
        $script:Runner = New-Object GuiProcessRunner
        $script:Runner.Start('powershell.exe', $args, $Here)
        Set-RunningState $true
        $lblStatus.Text = 'Status: Starting converter...'
        $timer.Start()
    } catch {
        if ($script:Runner) { $script:Runner.Dispose(); $script:Runner = $null }
        Set-RunningState $false
        [System.Windows.Forms.MessageBox]::Show($form, "Could not start the converter:`r`n$($_.Exception.Message)", 'Launch error', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnCancel.Add_Click({
    if ($script:Runner -and $script:Runner.IsRunning) {
        $answer = [System.Windows.Forms.MessageBox]::Show($form, 'Stop the active conversion? Any incomplete output may need to be converted again.', 'Cancel conversion', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $script:CancelRequested = $true
            $lblStatus.Text = 'Status: Cancelling...'
            try {
                $pidToKill = $script:Runner.ProcessId
                if ($pidToKill -gt 0) {
                    Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $pidToKill, '/T', '/F') -WindowStyle Hidden -Wait | Out-Null
                }
            } catch {}
        }
    }
})

$btnOpenOutput.Add_Click({
    if ($script:OutputFolder -and (Test-Path $script:OutputFolder)) { Start-Process explorer.exe -ArgumentList @($script:OutputFolder) }
})

$btnDlcManager.Add_Click({
    if (-not (Test-Path -LiteralPath $DlcManager -PathType Leaf)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'DLC Map Manager is missing from this folder.', 'Missing file', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    Save-GuiSettings
    $output = $txtOutput.Text.Trim().Trim('"')
    $recomp = $txtRecomp.Text.Trim().Trim('"')
    $cmd = '& ' + (Quote-PS $DlcManager) + ' -OutputRoot ' + (Quote-PS $output) + ' -RecompDir ' + (Quote-PS $recomp)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    try {
        Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Normal | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Could not open DLC Manager', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnInstallExisting.Add_Click({
    if (-not (Test-Path $Installer)) { return }
    $mapFolder = Select-Folder 'Select a converted map output folder containing Recomp-Content' $false
    if (-not $mapFolder) { return }
    $recomp = Select-Folder 'Select Skate3Recomp folder containing skate3.exe' $false
    if (-not $recomp) { return }
    if (-not (Test-Path (Join-Path $recomp 'skate3.exe'))) {
        [System.Windows.Forms.MessageBox]::Show($form, 'That folder does not contain skate3.exe.', 'Invalid Recomp folder', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $cmd = '& ' + (Quote-PS $Installer) + ' -MapOutputFolder ' + (Quote-PS $mapFolder) + ' -RecompDir ' + (Quote-PS $recomp)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    try {
        $p = Start-Process powershell.exe -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -Wait -PassThru
        if ($p.ExitCode -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($form, 'Converted map installed into Skate3Recomp.', 'Install complete', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show($form, "Installer exited with code $($p.ExitCode).", 'Install failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Install failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$form.Add_FormClosing({
    try { $groupStateTimer.Stop() } catch {}
    if ($script:Runner -and $script:Runner.IsRunning) {
        $answer = [System.Windows.Forms.MessageBox]::Show($form, 'A conversion is still running. Close the GUI and stop it?', 'Conversion running', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            $_.Cancel = $true
            return
        }
        try {
            $pidToKill = $script:Runner.ProcessId
            if ($pidToKill -gt 0) { Start-Process taskkill.exe -ArgumentList @('/PID',$pidToKill,'/T','/F') -WindowStyle Hidden -Wait | Out-Null }
        } catch {}
    }
    Save-GuiSettings
})

Load-GuiSettings
$txtRecomp.Enabled = $chkInstall.Checked
$btnRecomp.Enabled = $chkInstall.Checked
$txtGroup.Enabled = $true
Append-Log 'Ready. Choose a PS3 map archive or DIST folder.'
Sync-GroupUi
Append-Log 'v1.16: Replaces unsafe lightmap binding rewrites with selective repair of only texture assets actually referenced by material lightmap channels.'
[void]$form.ShowDialog()
