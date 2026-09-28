param(
    [string]$OutputRoot = "",
    [string]$RecompDir = ""
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Engine = Join-Path $Here 'Skate3-PS3-to-X360-Map-Importer.ps1'
$ManagerVersion = '1.17'
$SharedXuid = '0000000000000000'
$TitleId = '454108E6'
$MarketplaceType = '00000002'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

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

function New-Button([string]$Text, [int]$X, [int]$Y, [int]$W = 120, [int]$H = 32) {
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

function Select-Folder([string]$Description, [bool]$NewFolder = $false) {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $Description
    $dlg.ShowNewFolderButton = $NewFolder
    if ($dlg.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
    return ''
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

function Make-ContentId([string]$Text) {
    $s = $Text.ToUpperInvariant() -replace '[^A-Z0-9]+', '_'
    $s = $s.Trim('_')
    if ([string]::IsNullOrWhiteSpace($s)) { $s = 'CUSTOM_MAP' }
    if ($s.Length -gt 40) { $s = $s.Substring(0,40).TrimEnd('_') }
    return $s
}

function Make-DlcProductId([string]$Text) {
    $slug = Make-Slug $Text
    $alnum = $slug.ToUpperInvariant() -replace '[^A-Z0-9]', ''
    if ([string]::IsNullOrWhiteSpace($alnum)) { $alnum = 'CUSTOM' }
    if ($alnum.Length -gt 7) { $alnum = $alnum.Substring(0,7) }
    return $alnum.PadRight(16, '0').Substring(0,16)
}

function Resolve-Skate3UserDataRoot([string]$ExeRoot) {
    if (Test-Path (Join-Path $ExeRoot 'portable.txt')) { return $ExeRoot }
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) { throw 'APPDATA is unavailable.' }
    return (Join-Path $env:APPDATA 'skate3')
}

function Get-TitleRoot([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $null }
    $r = $Root.Trim().Trim('"')
    if ($r.EndsWith('skate3.exe', [System.StringComparison]::OrdinalIgnoreCase)) { $r = Split-Path -Parent $r }
    if (-not (Test-Path (Join-Path $r 'skate3.exe'))) { return $null }
    $userRoot = Resolve-Skate3UserDataRoot $r
    return (Join-Path $userRoot "$SharedXuid\$TitleId")
}

function Test-GameClosed {
    if (Get-Process -Name 'skate3' -ErrorAction SilentlyContinue) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Close Skate3Recomp before removing or rebuilding DLC content.', 'Skate3Recomp is running', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $false
    }
    return $true
}

function Remove-ContentRegistration([string]$TitleRoot, [string]$ContentId) {
    if ([string]::IsNullOrWhiteSpace($TitleRoot) -or [string]::IsNullOrWhiteSpace($ContentId)) { return $false }
    $removed = $false
    $contentDir = Join-Path $TitleRoot "$MarketplaceType\$ContentId"
    $headerPath = Join-Path $TitleRoot "Headers\$MarketplaceType\$ContentId.header"
    if (Test-Path -LiteralPath $contentDir) {
        Remove-Item -LiteralPath $contentDir -Recurse -Force
        $removed = $true
    }
    if (Test-Path -LiteralPath $headerPath) {
        Remove-Item -LiteralPath $headerPath -Force
        $removed = $true
    }
    return $removed
}

function Get-FolderSize([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [int64]0 }
    $sum = [int64]0
    foreach ($f in Get-ChildItem -LiteralPath $Path -File -Recurse -ErrorAction SilentlyContinue) { $sum += [int64]$f.Length }
    return $sum
}

function Format-Bytes([int64]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-InstalledStatus([string]$TitleRoot, [string[]]$Ids) {
    foreach ($id in $Ids) {
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        $dir = Join-Path $TitleRoot "$MarketplaceType\$id"
        $hdr = Join-Path $TitleRoot "Headers\$MarketplaceType\$id.header"
        if ((Test-Path -LiteralPath $dir -PathType Container) -or (Test-Path -LiteralPath $hdr -PathType Leaf)) {
            return [PSCustomObject]@{ Installed=$true; ContentId=$id; ContentDir=$dir; HeaderPath=$hdr; Size=(Get-FolderSize $dir) }
        }
    }
    $first = @($Ids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    $id0 = if ($first.Count -gt 0) { [string]$first[0] } else { '' }
    return [PSCustomObject]@{ Installed=$false; ContentId=$id0; ContentDir=''; HeaderPath=''; Size=[int64]0 }
}

function Read-JsonSafe([string]$Path) {
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) }
    } catch {}
    return $null
}

function Get-KnownDlcRecords([string]$OutputRootPath, [string]$TitleRoot) {
    $records = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($OutputRootPath) -or -not (Test-Path -LiteralPath $OutputRootPath -PathType Container)) { return @($records) }

    # Standalone converted maps.
    foreach ($dir in Get-ChildItem -LiteralPath $OutputRootPath -Directory -ErrorAction SilentlyContinue) {
        if ($dir.Name -ieq 'Location-Groups') { continue }
        $info = Read-JsonSafe (Join-Path $dir.FullName 'conversion-info.json')
        if ($null -eq $info) { continue }
        $name = if ($info.DisplayName) { [string]$info.DisplayName } else { $dir.Name }
        $id = if ($info.ContentId) { [string]$info.ContentId } else { Make-ContentId $name }
        $alt = Make-DlcProductId $name
        $status = Get-InstalledStatus $TitleRoot @($id, $alt)
        [void]$records.Add([PSCustomObject]@{
            Type='Standalone'
            Name=$name
            Count=1
            ContentId=[string]$status.ContentId
            Installed=[bool]$status.Installed
            Size=[int64]$status.Size
            OutputPath=$dir.FullName
            ProjectPath=''
            LegacyContentId=''
            Maps=@()
        })
    }

    # Stock-style parent Location groups.
    $groupsRoot = Join-Path $OutputRootPath 'Location-Groups'
    if (Test-Path -LiteralPath $groupsRoot -PathType Container) {
        foreach ($gdir in Get-ChildItem -LiteralPath $groupsRoot -Directory -ErrorAction SilentlyContinue) {
            $projectPath = Join-Path $gdir.FullName 'location-group.json'
            $project = Read-JsonSafe $projectPath
            if ($null -eq $project) { continue }
            $build = Read-JsonSafe (Join-Path $gdir.FullName 'group-build-info.json')
            $name = if ($project.GroupName) { [string]$project.GroupName } else { $gdir.Name }
            $maps = if ($project.Maps) { @($project.Maps) } else { @() }
            $id = if ($build -and $build.ContentId) { [string]$build.ContentId } else { Make-DlcProductId $name }
            $legacy = if ($build -and $build.LegacyV107ContentId) { [string]$build.LegacyV107ContentId } else { Make-ContentId $name }
            $status = Get-InstalledStatus $TitleRoot @($id, $legacy)
            [void]$records.Add([PSCustomObject]@{
                Type='Parent Group'
                Name=$name
                Count=$maps.Count
                ContentId=[string]$status.ContentId
                Installed=[bool]$status.Installed
                Size=[int64]$status.Size
                OutputPath=$gdir.FullName
                ProjectPath=$projectPath
                LegacyContentId=$legacy
                Maps=$maps
            })
        }
    }

    return @($records | Sort-Object @{Expression={ if ($_.Installed) {0} else {1} }}, Type, Name)
}

function Invoke-GroupRebuild([string]$ProjectPath, [string]$RecompPath) {
    if (-not (Test-Path -LiteralPath $Engine -PathType Leaf)) { throw 'Importer engine is missing.' }
    $cmd = '& ' + (Quote-PS $Engine) + ' -RebuildGroupProject ' + (Quote-PS $ProjectPath) + ' -RecompDir ' + (Quote-PS $RecompPath) + ' -InstallToRecomp -SkipInstallPrompt -NonInteractive'
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $p = Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Normal -Wait -PassThru
    return $p.ExitCode
}

function Save-ProjectWithMaps($Project, [object[]]$Maps, [string]$ProjectPath) {
    $Project.Maps = @($Maps)
    if ($Project.PSObject.Properties.Name -contains 'ExpectedMenuCount') { $Project.ExpectedMenuCount = @($Maps).Count }
    if ($Project.PSObject.Properties.Name -contains 'UpdatedAt') { $Project.UpdatedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    $Project | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ProjectPath -Encoding UTF8
}

function Refresh-Manager {
    $lst.Items.Clear()
    $lstChildren.Items.Clear()
    $script:Records = @()
    $script:SelectedRecord = $null

    $recomp = $txtRecomp.Text.Trim().Trim('"')
    $output = $txtOutput.Text.Trim().Trim('"')
    $titleRoot = Get-TitleRoot $recomp
    if ($null -eq $titleRoot) {
        $lblStatus.Text = 'Choose a valid Skate3Recomp folder.'
        $btnUninstall.Enabled = $false
        $btnRemoveChild.Enabled = $false
        return
    }
    if (-not (Test-Path -LiteralPath $output -PathType Container)) {
        $lblStatus.Text = 'Choose the converter output root that contains your converted maps.'
        $btnUninstall.Enabled = $false
        $btnRemoveChild.Enabled = $false
        return
    }

    $script:Records = @(Get-KnownDlcRecords $output $titleRoot)
    foreach ($r in $script:Records) {
        $item = New-Object System.Windows.Forms.ListViewItem($r.Type)
        [void]$item.SubItems.Add($r.Name)
        [void]$item.SubItems.Add([string]$r.Count)
        [void]$item.SubItems.Add($(if ($r.Installed) { 'Yes' } else { 'No' }))
        [void]$item.SubItems.Add([string]$r.ContentId)
        [void]$item.SubItems.Add($(if ($r.Installed) { Format-Bytes $r.Size } else { '-' }))
        [void]$lst.Items.Add($item)
    }

    $installedCount = @($script:Records | Where-Object { $_.Installed }).Count
    $lblStatus.Text = "Found $($script:Records.Count) importer record(s); $installedCount currently installed."
    $btnUninstall.Enabled = $false
    $btnRemoveChild.Enabled = $false
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Skate 3 Imported DLC Map Manager v$ManagerVersion"
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
$form.Size = New-Object System.Drawing.Size(980, 720)
$form.MinimumSize = New-Object System.Drawing.Size(900, 660)
$form.BackColor = [System.Drawing.Color]::FromArgb(30,30,32)
$form.ForeColor = [System.Drawing.Color]::WhiteSmoke
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'Imported DLC Map Manager'
$title.Location = New-Object System.Drawing.Point(18, 14)
$title.Size = New-Object System.Drawing.Size(500, 32)
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 17)
$title.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($title)

$desc = New-Object System.Windows.Forms.Label
$desc.Text = 'Uninstall converted DLCs from Skate3Recomp, or remove one child map from a stock-style parent group. Converted source/output files are kept.'
$desc.Location = New-Object System.Drawing.Point(20, 47)
$desc.Size = New-Object System.Drawing.Size(920, 36)
$desc.ForeColor = [System.Drawing.Color]::Silver
$form.Controls.Add($desc)

$form.Controls.Add((New-Label 'Skate3Recomp folder' 20 92 155))
$txtRecomp = New-TextBox 175 89 610 $RecompDir
$form.Controls.Add($txtRecomp)
$btnRecomp = New-Button 'Browse...' 795 87 125 30
$form.Controls.Add($btnRecomp)

$form.Controls.Add((New-Label 'Converter output root' 20 132 155))
$txtOutput = New-TextBox 175 129 610 $OutputRoot
$form.Controls.Add($txtOutput)
$btnOutput = New-Button 'Browse...' 795 127 125 30
$form.Controls.Add($btnOutput)

$btnRefresh = New-Button 'Refresh DLC List' 20 173 145 34
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(0,105,160)
$form.Controls.Add($btnRefresh)

$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Text = 'Only DLCs tied to conversion-info.json / location-group.json in this output root are managed, so stock/other DLC is not accidentally deleted.'
$lblNote.Location = New-Object System.Drawing.Point(180, 179)
$lblNote.Size = New-Object System.Drawing.Size(745, 28)
$lblNote.ForeColor = [System.Drawing.Color]::FromArgb(130,190,230)
$form.Controls.Add($lblNote)

$lst = New-Object System.Windows.Forms.ListView
$lst.Location = New-Object System.Drawing.Point(20, 218)
$lst.Size = New-Object System.Drawing.Size(920, 245)
$lst.View = [System.Windows.Forms.View]::Details
$lst.FullRowSelect = $true
$lst.MultiSelect = $false
$lst.HideSelection = $false
$lst.BackColor = [System.Drawing.Color]::FromArgb(22,22,24)
$lst.ForeColor = [System.Drawing.Color]::WhiteSmoke
$lst.GridLines = $true
[void]$lst.Columns.Add('Type', 105)
[void]$lst.Columns.Add('Name', 255)
[void]$lst.Columns.Add('Maps', 55)
[void]$lst.Columns.Add('Installed', 75)
[void]$lst.Columns.Add('Content ID', 245)
[void]$lst.Columns.Add('Size', 95)
$form.Controls.Add($lst)

$form.Controls.Add((New-Label 'Child maps in selected parent' 20 476 220))
$lstChildren = New-Object System.Windows.Forms.ListBox
$lstChildren.Location = New-Object System.Drawing.Point(20, 501)
$lstChildren.Size = New-Object System.Drawing.Size(920, 95)
$lstChildren.BackColor = [System.Drawing.Color]::FromArgb(22,22,24)
$lstChildren.ForeColor = [System.Drawing.Color]::WhiteSmoke
$form.Controls.Add($lstChildren)

$btnUninstall = New-Button 'Uninstall Selected DLC' 20 610 175 38
$btnUninstall.BackColor = [System.Drawing.Color]::FromArgb(125,55,55)
$btnUninstall.Enabled = $false
$form.Controls.Add($btnUninstall)

$btnRemoveChild = New-Button 'Remove Child from Parent' 205 610 195 38
$btnRemoveChild.BackColor = [System.Drawing.Color]::FromArgb(125,80,35)
$btnRemoveChild.Enabled = $false
$form.Controls.Add($btnRemoveChild)

$btnOpen = New-Button 'Open Output Folder' 410 610 155 38
$form.Controls.Add($btnOpen)

$btnClose = New-Button 'Close' 575 610 100 38
$form.Controls.Add($btnClose)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Choose paths, then Refresh DLC List.'
$lblStatus.Location = New-Object System.Drawing.Point(690, 612)
$lblStatus.Size = New-Object System.Drawing.Size(250, 36)
$lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$lblStatus.ForeColor = [System.Drawing.Color]::Gainsboro
$form.Controls.Add($lblStatus)

$script:Records = @()
$script:SelectedRecord = $null

$btnRecomp.Add_Click({
    $p = Select-Folder 'Select Skate3Recomp folder containing skate3.exe' $false
    if ($p) { $txtRecomp.Text = $p }
})

$btnOutput.Add_Click({
    $p = Select-Folder 'Select the Skate3-X360-Converted-Maps output root' $false
    if ($p) { $txtOutput.Text = $p }
})

$btnRefresh.Add_Click({ Refresh-Manager })

$lst.Add_SelectedIndexChanged({
    $lstChildren.Items.Clear()
    $script:SelectedRecord = $null
    $btnUninstall.Enabled = $false
    $btnRemoveChild.Enabled = $false
    if ($lst.SelectedIndices.Count -ne 1) { return }
    $i = $lst.SelectedIndices[0]
    if ($i -lt 0 -or $i -ge $script:Records.Count) { return }
    $r = $script:Records[$i]
    $script:SelectedRecord = $r
    $btnUninstall.Enabled = [bool]$r.Installed
    if ($r.Type -eq 'Parent Group') {
        foreach ($m in @($r.Maps)) {
            [void]$lstChildren.Items.Add(('{0}    [{1}]' -f [string]$m.DisplayName, [string]$m.WorldId))
        }
        $btnRemoveChild.Enabled = ($lstChildren.Items.Count -gt 0 -and [bool]$r.Installed)
        if ($lstChildren.Items.Count -gt 0) { $lstChildren.SelectedIndex = 0 }
    }
})

$btnUninstall.Add_Click({
    $r = $script:SelectedRecord
    if ($null -eq $r -or -not $r.Installed) { return }
    if (-not (Test-GameClosed)) { return }
    $msg = "Remove '$($r.Name)' from Skate3Recomp?`r`n`r`nThis removes the installed Content registration only. Your converted map files are kept so it can be installed again later."
    $answer = [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Uninstall imported DLC', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $titleRoot = Get-TitleRoot $txtRecomp.Text
        $removed = Remove-ContentRegistration $titleRoot ([string]$r.ContentId)
        if ($r.Type -eq 'Parent Group' -and $r.LegacyContentId) { [void](Remove-ContentRegistration $titleRoot ([string]$r.LegacyContentId)) }
        Refresh-Manager
        [System.Windows.Forms.MessageBox]::Show($form, "Removed '$($r.Name)' from Skate3Recomp.`r`n`r`nRestart the game if it was previously open.", 'DLC removed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Remove failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnRemoveChild.Add_Click({
    $r = $script:SelectedRecord
    if ($null -eq $r -or $r.Type -ne 'Parent Group') { return }
    if ($lstChildren.SelectedIndex -lt 0) { return }
    if (-not (Test-GameClosed)) { return }
    $mapIndex = $lstChildren.SelectedIndex
    $maps = @($r.Maps)
    if ($mapIndex -ge $maps.Count) { return }
    $target = $maps[$mapIndex]
    $remaining = @()
    for ($i=0; $i -lt $maps.Count; $i++) { if ($i -ne $mapIndex) { $remaining += $maps[$i] } }

    $msg = "Remove '$($target.DisplayName)' from parent '$($r.Name)'?`r`n`r`nThe parent package will be rebuilt with $($remaining.Count) remaining map(s). The converted map files themselves are NOT deleted."
    $answer = [System.Windows.Forms.MessageBox]::Show($form, $msg, 'Remove child map', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $projectPath = [string]$r.ProjectPath
    $project = Read-JsonSafe $projectPath
    if ($null -eq $project) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Could not read the parent location-group.json project.', 'Remove failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $backupText = Get-Content -LiteralPath $projectPath -Raw
    try {
        $titleRoot = Get-TitleRoot $txtRecomp.Text
        if ($remaining.Count -eq 0) {
            [void](Remove-ContentRegistration $titleRoot ([string]$r.ContentId))
            if ($r.LegacyContentId) { [void](Remove-ContentRegistration $titleRoot ([string]$r.LegacyContentId)) }
            if ($target.StandaloneContentId) { [void](Remove-ContentRegistration $titleRoot ([string]$target.StandaloneContentId)) }
            if ($target.StandaloneProductId) { [void](Remove-ContentRegistration $titleRoot ([string]$target.StandaloneProductId)) }
            Remove-Item -LiteralPath $r.OutputPath -Recurse -Force
            [System.Windows.Forms.MessageBox]::Show($form, "That was the final child. Parent '$($r.Name)' was uninstalled and its saved parent project was removed.`r`n`r`nThe converted map output remains in its normal per-map folder.", 'Parent removed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        } else {
            Save-ProjectWithMaps $project $remaining $projectPath
            $lblStatus.Text = 'Rebuilding parent package...'
            $form.UseWaitCursor = $true
            $code = Invoke-GroupRebuild $projectPath $txtRecomp.Text.Trim().Trim('"')
            $form.UseWaitCursor = $false
            if ($code -ne 0) {
                [System.IO.File]::WriteAllText($projectPath, $backupText, (New-Object System.Text.UTF8Encoding($true)))
                throw "Parent rebuild failed with exit code $code. The saved group project was restored."
            }
            if ($target.StandaloneContentId) { [void](Remove-ContentRegistration $titleRoot ([string]$target.StandaloneContentId)) }
            if ($target.StandaloneProductId) { [void](Remove-ContentRegistration $titleRoot ([string]$target.StandaloneProductId)) }
            [System.Windows.Forms.MessageBox]::Show($form, "Removed '$($target.DisplayName)' from '$($r.Name)'.`r`n`r`nThe parent was rebuilt and reinstalled with $($remaining.Count) child map(s).", 'Child removed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        }
        Refresh-Manager
    } catch {
        $form.UseWaitCursor = $false
        try {
            if ((Test-Path -LiteralPath $projectPath) -and $backupText) {
                # Only restore when the project still exists. Final-child removal intentionally deletes the group folder.
                if (Test-Path -LiteralPath (Split-Path -Parent $projectPath)) {
                    [System.IO.File]::WriteAllText($projectPath, $backupText, (New-Object System.Text.UTF8Encoding($true)))
                }
            }
        } catch {}
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Remove failed', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnOpen.Add_Click({
    $r = $script:SelectedRecord
    if ($r -and (Test-Path -LiteralPath $r.OutputPath)) { Start-Process explorer.exe -ArgumentList @($r.OutputPath) }
    elseif (Test-Path -LiteralPath $txtOutput.Text) { Start-Process explorer.exe -ArgumentList @($txtOutput.Text) }
})

$btnClose.Add_Click({ $form.Close() })

$form.Add_Shown({
    if (-not [string]::IsNullOrWhiteSpace($txtRecomp.Text) -and -not [string]::IsNullOrWhiteSpace($txtOutput.Text)) { Refresh-Manager }
})

[void]$form.ShowDialog()
