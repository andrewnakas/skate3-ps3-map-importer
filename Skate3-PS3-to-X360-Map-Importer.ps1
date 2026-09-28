param(
    [Parameter(Position=0)]
    [string]$SourcePath = "",
    [string]$OutputRoot = "",
    [string]$DisplayName = "",
    [string]$DistName = "",
    [double]$SpawnX = 0,
    [double]$SpawnY = 30,
    [double]$SpawnZ = 0,
    [double]$SpawnYaw = 0,
    [string]$GroupName = "",
    [switch]$NeutralizeLightmaps,
    [switch]$SuppressMacroOverlay,
    [switch]$BypassBakedLightmaps,
    [string]$RecompDir = "",
    [switch]$InstallToRecomp,
    [switch]$SkipInstallPrompt,
    [switch]$NonInteractive,
    [switch]$ForceToolchainRefresh,
    [switch]$KeepStaging,
    [string]$RebuildGroupProject = ""
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ImporterVersion = "1.16"
$ToolchainCacheVersion = "1.00"
$SafeAutomaticLightmapRepair = $false
$LegacyFullLightmapNeutralizationDisabled = $true

$ConverterUrl = "https://github.com/andrewnakas/skate3-ps3-to-x360.git"
$ConverterCommit = "1bbfb1893db656bfe5d9e81ae8b1547a2f5c9a36"
$ExternalUrl = "https://github.com/Ethanw05/DumbadsSkate3ModdingTools.git"
$ExternalCommit = "23a9d63f920bf1f77d5c2f639ebaa7c9f6424c82"

$SharedXuid = "0000000000000000"
$TitleId = "454108E6"
$MarketplaceType = "00000002"

$CacheRoot = Join-Path $env:LOCALAPPDATA "Skate3PS3ToX360MapImporter\v$ToolchainCacheVersion"
$ToolRoot = Join-Path $CacheRoot "skate3-ps3-to-x360"
$ExternalRoot = Join-Path $ToolRoot "external\DumbadsSkate3ModdingTools"
$ToolchainMarker = Join-Path $CacheRoot "toolchain-v$ToolchainCacheVersion-ready.txt"
$WorkingRoot = Join-Path $CacheRoot "working"

function Fail([string]$Message) {
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    exit 1
}

function Remove-UnsafeWorldUnlockRows([string]$UnlockRoot, [string]$Context = "DLC") {
    if ([string]::IsNullOrWhiteSpace($UnlockRoot) -or -not (Test-Path -LiteralPath $UnlockRoot -PathType Container)) {
        return 0
    }

    $removedTotal = 0
    foreach ($unlock in Get-ChildItem -LiteralPath $UnlockRoot -Filter "*.unlock" -File -ErrorAction SilentlyContinue) {
        $lines = @([System.IO.File]::ReadAllLines($unlock.FullName))
        $safeLines = @($lines | Where-Object { $_ -notmatch '^\s*WORLDS,' })
        $removed = $lines.Count - $safeLines.Count
        if ($removed -le 0) { continue }

        # Unlock files are plain ASCII CSV-style text. Keep the DLC_PRODUCT row(s)
        # and remove only WORLDS entitlements, which are unsafe for Skate3Recomp's
        # DLC scan and are already stripped by the standalone build-dlc path.
        [System.IO.File]::WriteAllLines($unlock.FullName, [string[]]$safeLines, [System.Text.Encoding]::ASCII)
        $removedTotal += $removed
        Write-Host "  stripped $removed unsafe WORLDS row(s) from $Context unlock: $($unlock.Name)" -ForegroundColor DarkYellow
    }

    return $removedTotal
}

function Refresh-Path {
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Resolve-Tool([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = switch ($Name) {
        "git" {
            @(
                "$env:ProgramFiles\Git\cmd\git.exe",
                "$env:ProgramFiles\Git\bin\git.exe",
                "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
                "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe"
            )
        }
        "dotnet" {
            @(
                "$env:ProgramFiles\dotnet\dotnet.exe",
                "${env:ProgramFiles(x86)}\dotnet\dotnet.exe"
            )
        }
        "7z" {
            @(
                "$env:ProgramFiles\7-Zip\7z.exe",
                "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
            )
        }
        default { @() }
    }

    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p)) { return (Resolve-Path $p).Path }
    }
    return $null
}

function Install-WingetPackage([string]$Id, [string]$Label) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Fail "$Label is required, but winget is not available. Install $Label manually and run the importer again."
    }

    Write-Host "Installing $Label..." -ForegroundColor Yellow
    Run-Checked $winget.Source @("install", "--id", $Id, "-e", "--accept-package-agreements", "--accept-source-agreements") "winget installation of $Label"
    Refresh-Path
}

function Ensure-Git {
    $git = Resolve-Tool "git"
    if (-not $git) {
        Install-WingetPackage "Git.Git" "Git"
        $git = Resolve-Tool "git"
    }
    if (-not $git) { Fail "Git could not be located after installation." }
    return $git
}

function Ensure-DotNet9 {
    $dotnet = Resolve-Tool "dotnet"
    $have9 = $false
    if ($dotnet) {
        try {
            $sdkCheck = Invoke-NativeProcess $dotnet @("--list-sdks")
            $have9 = ($sdkCheck.ExitCode -eq 0) -and [bool](($sdkCheck.StdOut -split "`r?`n") | Where-Object { $_ -match '^9\.' } | Select-Object -First 1)
        } catch { $have9 = $false }
    }

    if (-not $have9) {
        Install-WingetPackage "Microsoft.DotNet.SDK.9" ".NET 9 SDK"
        $dotnet = Resolve-Tool "dotnet"
        if ($dotnet) {
            $sdkCheck = Invoke-NativeProcess $dotnet @("--list-sdks")
            $have9 = ($sdkCheck.ExitCode -eq 0) -and [bool](($sdkCheck.StdOut -split "`r?`n") | Where-Object { $_ -match '^9\.' } | Select-Object -First 1)
        }
    }

    if (-not $dotnet -or -not $have9) {
        Fail ".NET 9 SDK is required by the PS3-to-X360 converter and could not be located."
    }
    return $dotnet
}

function Ensure-7Zip {
    $seven = Resolve-Tool "7z"
    if (-not $seven) {
        Install-WingetPackage "7zip.7zip" "7-Zip"
        $seven = Resolve-Tool "7z"
    }
    if (-not $seven) { Fail "7-Zip could not be located after installation." }
    return $seven
}

function ConvertTo-NativeCommandLineArg([string]$Value) {
    # ProcessStartInfo.Arguments is one Windows command-line string on Windows PowerShell 5.1.
    # Quote using the CommandLineToArgvW / C-runtime rules so paths with spaces, quotes,
    # and trailing backslashes survive intact.
    if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $slashes++
            continue
        }
        if ($ch -eq '"') {
            if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
            [void]$sb.Append('\')
            [void]$sb.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) {
            [void]$sb.Append(('\' * $slashes))
            $slashes = 0
        }
        [void]$sb.Append($ch)
    }
    if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Join-NativeCommandLine([string[]]$Arguments) {
    return (($Arguments | ForEach-Object { ConvertTo-NativeCommandLineArg ([string]$_) }) -join ' ')
}

function Invoke-NativeProcess([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory = '') {
    # Do NOT invoke console tools through PowerShell's native-command adapter here.
    # Git intentionally writes clone/fetch progress to STDERR even on success, and with
    # $ErrorActionPreference='Stop' Windows PowerShell can promote that normal text to a
    # terminating NativeCommandError. ProcessStartInfo lets the real process exit code be
    # authoritative while still preserving both output streams as ordinary text.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = Join-NativeCommandLine $Arguments
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { throw "Process could not be started: $Exe" }
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = $outTask.Result
        $stderr = $errTask.Result
        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            StdOut = [string]$stdout
            StdErr = [string]$stderr
        }
    } finally {
        $proc.Dispose()
    }
}

function Write-NativeText([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { Write-Host $line }
    }
}

function Get-NativeFailureDetail($Result) {
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($Result.StdErr)) { $lines += ($Result.StdErr -split "`r?`n") }
    if (-not [string]::IsNullOrWhiteSpace($Result.StdOut)) { $lines += ($Result.StdOut -split "`r?`n") }
    $last = $lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1
    if ($last) { return " Last message: $last" }
    return ''
}

function Run-Checked([string]$Exe, [string[]]$Arguments, [string]$What) {
    $result = Invoke-NativeProcess $Exe $Arguments
    Write-NativeText $result.StdOut
    Write-NativeText $result.StdErr
    if ($result.ExitCode -ne 0) {
        $detail = Get-NativeFailureDetail $result
        Fail "$What failed with exit code $($result.ExitCode).$detail"
    }
}

function Run-LoggedChecked([string]$Exe, [string[]]$Arguments, [string]$What, [string]$LogPath) {
    $parent = Split-Path -Parent $LogPath
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $result = Invoke-NativeProcess $Exe $Arguments
    $combined = @($result.StdOut, $result.StdErr) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($LogPath, $combined, (New-Object System.Text.UTF8Encoding($false)))
    Write-NativeText $result.StdOut
    Write-NativeText $result.StdErr
    if ($result.ExitCode -ne 0) {
        $detail = Get-NativeFailureDetail $result
        Fail "$What failed with exit code $($result.ExitCode).$detail See $LogPath"
    }
}

function Run-CheckedInDirectory([string]$Exe, [string[]]$Arguments, [string]$WorkingDirectory, [string]$What) {
    $result = Invoke-NativeProcess $Exe $Arguments $WorkingDirectory
    Write-NativeText $result.StdOut
    Write-NativeText $result.StdErr
    if ($result.ExitCode -ne 0) {
        $detail = Get-NativeFailureDetail $result
        Fail "$What failed with exit code $($result.ExitCode).$detail"
    }
}

function Run-EABigFilePack([string]$Exe, [string]$OutputName, [string]$WorkingDirectory) {
    # bigfile.exe writes harmless directory-probe failures to STDERR while recursively
    # packing data/*.  Calling it directly from a PowerShell pipeline can promote that
    # STDERR text into a terminating NativeCommandError when the GUI worker merges streams.
    # Use ProcessStartInfo so STDERR stays plain text, then distinguish a directory probe
    # from a real missing-file error before deciding whether the pack failed.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = ('"{0}" data/* -r -fat' -f $OutputName.Replace('"', '\"'))

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        if (-not $proc.Start()) { Fail "EA BIG packing could not start bigfile.exe." }
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
        $exitCode = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($stdout)) {
        foreach ($line in ($stdout -split "`r?`n")) { $lines.Add($line) }
    }
    if (-not [string]::IsNullOrEmpty($stderr)) {
        foreach ($line in ($stderr -split "`r?`n")) { $lines.Add($line) }
    }

    $hardErrors = New-Object System.Collections.Generic.List[string]
    $directoryProbeCount = 0
    $addedCount = 0
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $trimmed = $line.Trim()

        if ($trimmed.StartsWith('Added file ', [System.StringComparison]::OrdinalIgnoreCase)) {
            $addedCount++
            continue
        }

        if ($trimmed -match '^bigfile:\s+failed to open\s+(.+?)\s+for reading\s*$') {
            $reportedPath = $Matches[1].Trim().Trim('"')
            $relativePath = $reportedPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
            $candidate = Join-Path $WorkingDirectory $relativePath
            if (Test-Path -LiteralPath $candidate -PathType Container) {
                $directoryProbeCount++
                continue
            }
            $hardErrors.Add($trimmed)
            Write-Host $line -ForegroundColor Red
            continue
        }

        Write-Host $line
        if ($trimmed -match '(?i)\b(error|failed|fatal)\b') {
            $hardErrors.Add($trimmed)
        }
    }

    if ($addedCount -gt 0) {
        Write-Host "  bigfile.exe packed $addedCount file(s)." -ForegroundColor DarkGray
    }
    if ($directoryProbeCount -gt 0) {
        Write-Host "  ignored $directoryProbeCount harmless recursive directory probe(s) from bigfile.exe." -ForegroundColor DarkYellow
    }

    $outputPath = Join-Path $WorkingDirectory $OutputName
    $outputExists = Test-Path -LiteralPath $outputPath -PathType Leaf
    $outputSize = if ($outputExists) { (Get-Item -LiteralPath $outputPath).Length } else { 0 }

    if ($exitCode -ne 0) {
        if ($hardErrors.Count -eq 0 -and $outputExists -and $outputSize -ge 1MB) {
            Write-Host "  bigfile.exe returned exit code $exitCode after harmless directory probing; accepting the completed BIG." -ForegroundColor Yellow
        } else {
            $detail = if ($hardErrors.Count -gt 0) { ' ' + ($hardErrors -join ' | ') } else { '' }
            Fail "EA BIG packing failed with exit code $exitCode.$detail"
        }
    }

    if (-not $outputExists) { Fail "EA bigfile.exe did not create $outputPath" }
    if ($outputSize -lt 1MB) { Fail "EA-packed BIG is unexpectedly small ($outputSize bytes)." }
    return $outputPath
}

function Select-ArchiveOrFolder {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "Choose YES for a PS3 map archive (.rar/.zip/.7z).`r`nChoose NO for an already-extracted DIST_* folder.",
            "Skate 3 PS3 -> Xbox 360 Map Importer",
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title = "Select PS3 Skate 3 map archive"
            $dialog.Filter = "Map archives (*.rar;*.zip;*.7z)|*.rar;*.zip;*.7z|All files (*.*)|*.*"
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
            return ""
        }

        if ($choice -eq [System.Windows.Forms.DialogResult]::No) {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = "Select the extracted PS3 DIST_* map folder (or its parent folder)"
            $dialog.ShowNewFolderButton = $false
            if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
            return ""
        }
    } catch {}

    return (Read-Host "Paste the PS3 map archive or extracted folder path").Trim().Trim('"')
}

function Select-Folder([string]$Description) {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
    } catch {}
    return ""
}

function Resolve-Ps3WorldId([string]$MapDir) {
    # Prefer canonical DIST_* manifests, but accept custom-export folders whose
    # wrapper/leaf name is not DIST_* as long as the manifest itself identifies
    # the world. This is common in archives that contain an extra author folder.
    $manifestPatterns = @(
        @{ Filter = "DIST_*_Pres.psm"; Suffix = "_Pres" },
        @{ Filter = "*_Pres.psm";      Suffix = "_Pres" },
        @{ Filter = "DIST_*_Sim.psm";  Suffix = "_Sim"  },
        @{ Filter = "*_Sim.psm";       Suffix = "_Sim"  }
    )

    foreach ($pattern in $manifestPatterns) {
        $matches = @(Get-ChildItem -LiteralPath $MapDir -Filter $pattern.Filter -File -ErrorAction SilentlyContinue |
            Sort-Object Name)
        foreach ($m in $matches) {
            $base = $m.BaseName
            if ($base.EndsWith($pattern.Suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $world = $base.Substring(0, $base.Length - $pattern.Suffix.Length)
                if ($world -match '^(?i)dist_(.+)$') { return "DIST_$($Matches[1])" }
                if (-not [string]::IsNullOrWhiteSpace($world)) { return $world }
            }
        }
    }

    # Some community archives include stream XML sidecars even when the leaf
    # directory is a generic wrapper.
    $xml = Get-ChildItem -LiteralPath $MapDir -Filter "dist_*_Pres.xml" -File -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -First 1
    if ($xml -and $xml.BaseName -match '^(?i)dist_(.+)_Pres$') {
        return "DIST_$($Matches[1])"
    }

    $leaf = Split-Path -Leaf $MapDir
    if ($leaf -match '^(?i)dist_(.+)$') { return "DIST_$($Matches[1])" }
    return ""
}

function Get-DistCandidateScore([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return -1 }

    $pres = @(Get-ChildItem -LiteralPath $Dir -Filter "cPres*.psf" -File -ErrorAction SilentlyContinue)
    if ($pres.Count -eq 0) { return -1 }

    $sim = @(Get-ChildItem -LiteralPath $Dir -Filter "cSim*.psf" -File -ErrorAction SilentlyContinue)
    $tex = @(Get-ChildItem -LiteralPath $Dir -Filter "cTex*.psf" -File -ErrorAction SilentlyContinue)
    $psm = @(Get-ChildItem -LiteralPath $Dir -Filter "*_Pres.psm" -File -ErrorAction SilentlyContinue)
    $manifestFiles = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match '^\.(psm|pmm|pss|pst)$' })

    $leaf = Split-Path -Leaf $Dir
    $score = 1000 + ($pres.Count * 3) + ($sim.Count * 2) + $tex.Count + ($manifestFiles.Count * 20)
    if ($psm.Count -gt 0) { $score += 500 }
    if ($leaf -like 'DIST_*') { $score += 250 }
    if (Test-Path (Join-Path $Dir 'cPres_Global.psf')) { $score += 50 }
    return $score
}

function Test-DistLikeFolder([string]$Dir) {
    return (Get-DistCandidateScore $Dir) -ge 1000
}

function Find-DistFolders([string]$Root) {
    $rows = New-Object System.Collections.Generic.List[object]
    $allDirs = New-Object System.Collections.Generic.List[string]
    $allDirs.Add($Root)

    Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { $allDirs.Add($_.FullName) }

    foreach ($dir in $allDirs) {
        $score = Get-DistCandidateScore $dir
        if ($score -lt 1000) { continue }
        $resolved = (Resolve-Path -LiteralPath $dir).Path
        $world = Resolve-Ps3WorldId $resolved
        if ([string]::IsNullOrWhiteSpace($world)) { continue }

        $depth = ($resolved.TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) -split '[\\/]').Count
        $rows.Add([PSCustomObject]@{
            Path = $resolved
            World = $world
            Score = $score
            Depth = $depth
        })
    }

    # Archives sometimes contain both a wrapper that happens to contain cPres
    # files and the real deeper DIST folder. Suppress only ancestor/descendant
    # duplicates of the SAME world. Do not collapse unrelated folders merely
    # because two community maps were exported from the same DIST template.
    $chosen = New-Object System.Collections.Generic.List[object]
    $ordered = @($rows | Sort-Object Score, Depth -Descending)
    foreach ($row in $ordered) {
        $rowPath = ([string]$row.Path).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
        $duplicateWrapper = $false
        foreach ($kept in $chosen) {
            if ([string]$kept.World -ine [string]$row.World) { continue }
            $keptPath = ([string]$kept.Path).TrimEnd([char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
            $rowUnderKept = $rowPath.StartsWith($keptPath + '\', [System.StringComparison]::OrdinalIgnoreCase)
            $keptUnderRow = $keptPath.StartsWith($rowPath + '\', [System.StringComparison]::OrdinalIgnoreCase)
            if ($rowUnderKept -or $keptUnderRow) {
                $duplicateWrapper = $true
                break
            }
        }
        if (-not $duplicateWrapper) { $chosen.Add($row) }
    }

    return @($chosen | ForEach-Object { $_.Path })
}

function Expand-MapArchive([string]$ArchivePath, [string]$Destination) {
    $seven = Ensure-7Zip
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    # Use 7-Zip for ZIP too. Expand-Archive is convenient but is much less
    # tolerant of community archives with odd attributes/path shapes.
    Run-Checked $seven @("x", "-y", "-aoa", "-o$Destination", $ArchivePath) "Extracting map archive"
}

function Expand-NestedMapArchives([string]$Root, [string]$SessionRoot, [int]$MaxDepth = 2) {
    $seven = Ensure-7Zip
    $processed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $currentRoot = $Root

    for ($depth = 1; $depth -le $MaxDepth; $depth++) {
        $nested = @(Get-ChildItem -LiteralPath $currentRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension.ToLowerInvariant() -in @('.rar','.zip','.7z') } |
            Where-Object { -not $processed.Contains($_.FullName) })

        if ($nested.Count -eq 0) { break }
        if ($nested.Count -gt 32) {
            Write-Host "WARNING: archive contains $($nested.Count) nested archives; only the first 32 will be inspected." -ForegroundColor Yellow
            $nested = @($nested | Select-Object -First 32)
        }

        Write-Host "No DIST found yet; scanning $($nested.Count) nested archive(s), depth $depth..." -ForegroundColor Yellow
        foreach ($arc in $nested) {
            [void]$processed.Add($arc.FullName)
            $safe = [System.IO.Path]::GetFileNameWithoutExtension($arc.Name) -replace '[^A-Za-z0-9._-]+','_'
            # Keep the nested extraction underneath the original extraction
            # tree so the normal recursive DIST scanner sees it immediately.
            $dest = Join-Path (Split-Path -Parent $arc.FullName) ("__importer_nested_{0}_{1}_{2}" -f $depth, $safe, ([Guid]::NewGuid().ToString('N').Substring(0,8)))
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            $nestedResult = Invoke-NativeProcess $seven @("x", "-y", "-aoa", "-o$dest", $arc.FullName)
            if ($nestedResult.ExitCode -ne 0) {
                $detail = Get-NativeFailureDetail $nestedResult
                Write-Host "WARNING: could not inspect nested archive '$($arc.FullName)'.$detail" -ForegroundColor Yellow
                continue
            }
            $currentRoot = $Root
        }
    }
}

function Select-DistFolder([string[]]$Candidates, [string]$RequestedDist) {
    if ($Candidates.Count -eq 0) { return "" }

    if (-not [string]::IsNullOrWhiteSpace($RequestedDist)) {
        $requested = $RequestedDist.Trim()
        $match = $Candidates | Where-Object {
            $leaf = Split-Path -Leaf $_
            $resolvedWorld = Resolve-Ps3WorldId $_
            $leaf -ieq $requested -or $resolvedWorld -ieq $requested
        } | Select-Object -First 1
        if ($match) { return $match }
        Fail "Requested DIST '$RequestedDist' was not found anywhere inside the selected source/archive."
    }

    if ($Candidates.Count -eq 1) { return $Candidates[0] }

    if ($NonInteractive) {
        $names = @($Candidates | ForEach-Object {
            $w = Resolve-Ps3WorldId $_
            if ($w) { "$w [$($_)]" } else { $_ }
        })
        Fail "Multiple PS3 DIST maps were found recursively ($($names -join '; ')). Enter the exact source DIST name in the GUI and run again."
    }

    Write-Host ""
    Write-Host "Multiple PS3 DIST maps were found:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Candidates.Count; $i++) {
        $w = Resolve-Ps3WorldId $Candidates[$i]
        Write-Host "  [$($i + 1)] $w  ($($Candidates[$i]))"
    }
    do {
        $pick = Read-Host "Choose the map number"
        $n = 0
        $ok = [int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $Candidates.Count
    } until ($ok)
    return $Candidates[$n - 1]
}

function Validate-Ps3Dist([string]$MapDir, [string]$WorldId) {
    if ([string]::IsNullOrWhiteSpace($WorldId)) {
        Fail "Could not determine the source DIST world ID from the folder/manifests."
    }

    $presStreams = @(Get-ChildItem -LiteralPath $MapDir -Filter "cPres*.psf" -File -ErrorAction SilentlyContinue)
    if ($presStreams.Count -eq 0) {
        Fail "The selected DIST has no cPres*.psf presentation streams, so there is no render world to convert."
    }

    foreach ($kind in @('Pres','Sim','Tex')) {
        $manifestExts = @('psm','pmm','pss','pst')
        $existing = @($manifestExts | Where-Object { Test-Path (Join-Path $MapDir "${WorldId}_${kind}.$_") })
        if ($kind -eq 'Pres' -and $existing.Count -eq 0) {
            Fail "The selected DIST is missing its ${WorldId}_Pres.psm/.pmm/.pss/.pst manifest set."
        }
        if ($existing.Count -gt 0 -and $existing.Count -lt 4) {
            $missing = @($manifestExts | Where-Object { -not (Test-Path (Join-Path $MapDir "${WorldId}_${kind}.$_")) })
            Fail "The selected DIST has an incomplete $kind manifest set. Missing: $($missing -join ', ')"
        }
    }

    if (-not (Test-Path (Join-Path $MapDir 'cPres_Global.psf'))) {
        Write-Host "NOTE: cPres_Global.psf is not present. Continuing because the map has other cPres streams." -ForegroundColor Yellow
    }

    $simStreams = @(Get-ChildItem -LiteralPath $MapDir -Filter "cSim*.psf" -File -ErrorAction SilentlyContinue)
    if ($simStreams.Count -eq 0) {
        Write-Host "WARNING: no cSim*.psf streams were found. The map may have no usable collision/simulation data." -ForegroundColor Yellow
    } elseif (-not (Test-Path (Join-Path $MapDir 'cSim_Global.psf'))) {
        Write-Host "NOTE: cSim_Global.psf is not present. This is allowed; converting the $($simStreams.Count) Sim stream(s) that do exist." -ForegroundColor Yellow
    }

    $texStreams = @(Get-ChildItem -LiteralPath $MapDir -Filter "cTex*.psf" -File -ErrorAction SilentlyContinue)
    Write-Host "Source stream summary: Pres=$($presStreams.Count)  Sim=$($simStreams.Count)  Tex=$($texStreams.Count)" -ForegroundColor DarkGray
    if ($texStreams.Count -gt 0) {
        Write-Host "Texture note: this map has cTex baked-light streams. v1.16 preserves authored payloads by default; use selective referenced-lightmap repair only when this map shows a wrong/repeated baked-light texture layer." -ForegroundColor DarkYellow
    }
}

function Normalize-SourceDistFolder([string]$MapDir, [string]$WorldId, [string]$SessionRoot) {
    $leaf = Split-Path -Leaf $MapDir
    if ($leaf -ieq $WorldId) { return $MapDir }

    $normalizedRoot = Join-Path $SessionRoot 'normalized-source'
    $normalized = Join-Path $normalizedRoot $WorldId
    New-Item -ItemType Directory -Force -Path $normalized | Out-Null
    Get-ChildItem -LiteralPath $MapDir -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $normalized -Recurse -Force
    }
    Write-Host "Normalized source folder '$leaf' to '$WorldId' for the converter." -ForegroundColor DarkGray
    return $normalized
}

function Make-TargetWorldId([string]$DisplayName) {
    $name = $DisplayName -replace '[^A-Za-z0-9]+', '_'
    $name = $name.Trim('_')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = 'CustomMap' }
    if ($name.Length -gt 48) { $name = $name.Substring(0,48).TrimEnd('_') }
    return "DIST_$name"
}

function Make-Slug([string]$Text) {
    $s = $Text.ToLowerInvariant() -replace '[^a-z0-9]+', '_'
    $s = $s.Trim('_')
    if ([string]::IsNullOrWhiteSpace($s)) { $s = "custom_map" }
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).TrimEnd('_') }
    return $s
}

function Make-ContentId([string]$Text) {
    $s = $Text.ToUpperInvariant() -replace '[^A-Z0-9]+', '_'
    $s = $s.Trim('_')
    if ([string]::IsNullOrWhiteSpace($s)) { $s = "CUSTOM_MAP" }
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).TrimEnd('_') }
    return $s
}

function Make-DlcProductId([string]$Text) {
    # Must mirror DlcBuilder.Core BuildDlcMappingCollection exactly:
    # package slug -> strip non-alnum -> uppercase -> first 7 chars -> pad to 16.
    # The builder documents that product_id must match the installed content folder.
    $slug = Make-Slug $Text
    $alnum = $slug.ToUpperInvariant() -replace '[^A-Z0-9]', ''
    if ([string]::IsNullOrWhiteSpace($alnum)) { $alnum = 'CUSTOM' }
    if ($alnum.Length -gt 7) { $alnum = $alnum.Substring(0,7) }
    return $alnum.PadRight(16, '0').Substring(0,16)
}

function Update-LocationGroupProject(
    [string]$GroupDisplayName,
    [string]$OutputRootPath,
    [string]$MapDisplayName,
    [string]$WorldId,
    [string]$ConvertedDistPath,
    [double]$X,
    [double]$Y,
    [double]$Z,
    [double]$Yaw
) {
    $groupSlug = Make-Slug $GroupDisplayName
    $groupRoot = Join-Path $OutputRootPath "Location-Groups\$groupSlug"
    $projectPath = Join-Path $groupRoot "location-group.json"
    New-Item -ItemType Directory -Force -Path $groupRoot | Out-Null

    $existingMaps = @()
    if (Test-Path -LiteralPath $projectPath) {
        try {
            $old = Get-Content -LiteralPath $projectPath -Raw | ConvertFrom-Json
            if ($old.Maps) { $existingMaps = @($old.Maps) }
        } catch {
            Fail "Could not read the existing Location Group project: $projectPath"
        }
    }

    $maps = New-Object System.Collections.ArrayList
    foreach ($m in $existingMaps) {
        # Re-converting a map with the same X360 world replaces its old entry
        # without changing the rest of the group's ordering.
        if ([string]$m.WorldId -ieq $WorldId) { continue }
        [void]$maps.Add($m)
    }

    [void]$maps.Add([PSCustomObject]@{
        DisplayName = $MapDisplayName
        WorldId = $WorldId
        DistFolderPath = [System.IO.Path]::GetFullPath($ConvertedDistPath)
        SlugSuffix = Make-Slug $MapDisplayName
        StandaloneContentId = Make-ContentId $MapDisplayName
        StandaloneProductId = Make-DlcProductId $MapDisplayName
        StandalonePackageName = "$(Make-Slug $MapDisplayName)_00000000.big"
        SpawnX = $X
        SpawnY = $Y
        SpawnZ = $Z
        SpawnYaw = $Yaw
    })

    $project = [PSCustomObject]@{
        FormatVersion = 3
        GroupName = $GroupDisplayName
        ParentLocationName = $GroupDisplayName
        GroupSlug = $groupSlug
        MenuShape = "ParentCategoryWithChildFreeskateLocations"
        ExpectedMenuCount = @($maps).Count
        UpdatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Maps = @($maps)
    }
    $project | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $projectPath -Encoding UTF8

    return [PSCustomObject]@{
        Root = $groupRoot
        ProjectPath = $projectPath
        GroupName = $GroupDisplayName
        GroupSlug = $groupSlug
        Maps = @($maps)
    }
}

function Build-LocationGroupPackage(
    $Project,
    $Tools,
    [string]$StagingData,
    [string]$SessionRootPath,
    [bool]$KeepGroupStaging
) {
    if ($null -eq $Project -or $Project.Maps.Count -eq 0) {
        Fail "Location Group has no maps to package."
    }

    foreach ($m in $Project.Maps) {
        if (-not (Test-Path -LiteralPath ([string]$m.DistFolderPath) -PathType Container)) {
            Fail "Location Group '$($Project.GroupName)' references a converted DIST that no longer exists: $($m.DistFolderPath)"
        }
    }

    Write-Host ""
    Write-Host "Rebuilding Location Group '$($Project.GroupName)' with $($Project.Maps.Count) map(s)..." -ForegroundColor Cyan

    $groupBuildOut = Join-Path $SessionRootPath "group-builder-output"
    $configPath = Join-Path $SessionRootPath "group-build.json"
    $cfgMaps = @($Project.Maps | ForEach-Object {
        [PSCustomObject]@{
            DistFolderPath = [string]$_.DistFolderPath
            DisplayName = [string]$_.DisplayName
            SlugSuffix = [string]$_.SlugSuffix
            SpawnX = [double]$_.SpawnX
            SpawnY = [double]$_.SpawnY
            SpawnZ = [double]$_.SpawnZ
            SpawnYaw = [double]$_.SpawnYaw
        }
    })
    [PSCustomObject]@{
        PackageName = [string]$Project.GroupName
        OutputDirectory = $groupBuildOut
        Maps = $cfgMaps
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8

    Remove-Item -LiteralPath $StagingData -Recurse -Force -ErrorAction SilentlyContinue
    Run-Checked $Tools.DotNet @($Tools.CliDll, "build-group-staging", $configPath) "Building grouped Locations staging tree"

    if (-not (Test-Path -LiteralPath $StagingData -PathType Container)) {
        Fail "Grouped DLC builder produced no staging tree at $StagingData"
    }

    # v1.09 grouped-menu sanity gate. A stock-style parent is ONE package/listing
    # whose filter resolves N child freeskate rows. Verify the staging tree really
    # contains N per-area local-data rows before we ever pack/install it.
    $challengeLocalDir = Join-Path $StagingData "db\challenge_local_data"
    $childVlt = @()
    if (Test-Path -LiteralPath $challengeLocalDir) {
        $childVlt = @(Get-ChildItem -LiteralPath $challengeLocalDir -Filter "freeskate_dlc_*.vlt" -File -ErrorAction SilentlyContinue)
    }
    if ($childVlt.Count -ne $Project.Maps.Count) {
        Fail "Grouped staging has $($childVlt.Count) child freeskate row(s), expected $($Project.Maps.Count). Refusing to install a fake/flattened parent package."
    }
    $expectedManifest = Join-Path $StagingData ("db\dlc_{0}_minimal.vlt" -f $Project.GroupSlug)
    if (-not (Test-Path -LiteralPath $expectedManifest -PathType Leaf)) {
        Fail "Grouped package manifest is missing: $expectedManifest"
    }
    $expectedProductId = Make-DlcProductId $Project.GroupName
    Write-Host "Group staging verified: ONE parent package -> $($childVlt.Count) child freeskate row(s)." -ForegroundColor Green
    Write-Host "Group manifest product_id/content folder: $expectedProductId" -ForegroundColor DarkGray

    # The grouped orchestrator writes fresh unlock files after the standalone map
    # conversion, so it reintroduces WORLDS entitlement rows that the normal
    # build-dlc path already strips. Remove only those rows, preserve DLC_PRODUCT,
    # then verify the staging tree is safe before EA BIG packing.
    $unlockDir = Join-Path $StagingData "unlocks"
    $groupWorldRowsRemoved = Remove-UnsafeWorldUnlockRows $unlockDir "grouped"
    if ($groupWorldRowsRemoved -gt 0) {
        Write-Host "Grouped unlock sanitization complete: removed $groupWorldRowsRemoved WORLDS row(s)." -ForegroundColor Green
    }
    if (Test-Path $unlockDir) {
        foreach ($unlock in Get-ChildItem -LiteralPath $unlockDir -Filter "*.unlock" -File -ErrorAction SilentlyContinue) {
            if (Select-String -LiteralPath $unlock.FullName -Pattern '^\s*WORLDS,' -Quiet -ErrorAction SilentlyContinue) {
                Fail "Grouped staging still contains an unsafe WORLDS unlock row after sanitization: $($unlock.FullName)"
            }
        }
    }

    $groupDlcDir = Join-Path $Project.Root "DLC"
    $groupRecompRoot = Join-Path $Project.Root "Recomp-Content"
    New-Item -ItemType Directory -Force -Path $groupDlcDir | Out-Null

    $groupPackageName = "$($Project.GroupSlug)_00000000.big"
    $eaName = "$($Project.GroupSlug)_group_x360_ea.big"
    $eaPath = Join-Path $Tools.CliBinDir $eaName
    Remove-Item -LiteralPath $eaPath -Force -ErrorAction SilentlyContinue

    Write-Host "Packing grouped Xbox 360 DLC with EA bigfile.exe..." -ForegroundColor Cyan
    $packed = Run-EABigFilePack $Tools.BigFileExe $eaName $Tools.CliBinDir
    if (-not [string]::Equals($packed, $eaPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "EA BIG packer returned an unexpected grouped output path: $packed"
    }

    $finalBig = Join-Path $groupDlcDir $groupPackageName
    Copy-Item -LiteralPath $eaPath -Destination $finalBig -Force
    Remove-Item -LiteralPath $eaPath -Force -ErrorAction SilentlyContinue

    Remove-Item -LiteralPath $groupRecompRoot -Recurse -Force -ErrorAction SilentlyContinue
    # v1.09: match the retail/DlcBuilder product_id exactly. v1.07 used a pretty
    # ContentID such as CUSTOM_MAPS while the manifest said CUSTOMM000000000;
    # that mismatch can prevent the package from behaving like one stock-style
    # Locations parent even though the BIG itself mounts.
    $groupContentId = Make-DlcProductId $Project.GroupName
    $legacyGroupContentId = Make-ContentId $Project.GroupName
    $contentDir = Join-Path $groupRecompRoot "$SharedXuid\$TitleId\$MarketplaceType\$groupContentId"
    $header = Join-Path $groupRecompRoot "$SharedXuid\$TitleId\Headers\$MarketplaceType\$groupContentId.header"
    New-Item -ItemType Directory -Force -Path $contentDir | Out-Null
    Copy-Item -LiteralPath $finalBig -Destination (Join-Path $contentDir $groupPackageName) -Force
    Write-XboxContentHeader $header $groupContentId $Project.GroupName

    if ($KeepGroupStaging) {
        $debug = Join-Path $Project.Root "X360-DLC-Staging"
        Remove-Item -LiteralPath $debug -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $StagingData -Destination $debug -Recurse -Force
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $finalBig).Hash
    $members = @($Project.Maps | ForEach-Object { " - $($_.DisplayName)  [$($_.WorldId)]" }) -join [Environment]::NewLine

    [PSCustomObject]@{
        ImporterVersion = $ImporterVersion
        GroupName = $Project.GroupName
        ParentLocationName = $Project.GroupName
        GroupSlug = $Project.GroupSlug
        MenuShape = "ParentCategoryWithChildFreeskateLocations"
        ExpectedTopLevelLabel = "$($Project.GroupName) ($($Project.Maps.Count))"
        ExpectedMenuCount = $Project.Maps.Count
        ContentId = $groupContentId
        LegacyV107ContentId = $legacyGroupContentId
        ManifestProductId = $groupContentId
        PackageName = $groupPackageName
        BigSha256 = $hash
        Maps = @($Project.Maps)
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Project.Root "group-build-info.json") -Encoding UTF8

    $readme = @"
Skate 3 PS3 -> Xbox 360 LOCATION GROUP

Group: $($Project.GroupName)
Maps:  $($Project.Maps.Count)
BIG:   $groupPackageName
SHA-256: $hash

This is a stock-style Locations parent/category containing multiple freeskate maps.
Expected top-level menu shape:
    $($Project.GroupName) ($($Project.Maps.Count))

Selecting that parent once opens the next-level child list. Each child below is
a separate converted DIST_* world, not merely another spawn in one world:

$members

To add or update a map, convert it again in the importer with the SAME
Location Group name. The importer updates location-group.json and rebuilds
this package with all saved members.

The converted-map output folders remain on disk for reuse. When this grouped
package is installed, v1.16 removes the matching standalone Recomp content
registrations for its member maps so the top-level menu collapses to this one
parent instead of leaving the old Name (1) entries beside it.
"@
    Set-Content -LiteralPath (Join-Path $Project.Root "README-LOCATION-GROUP.txt") -Value $readme -Encoding UTF8

    Write-Host "Grouped Locations package complete:" -ForegroundColor Green
    Write-Host "  $finalBig"
    Write-Host "  In-game parent: $($Project.GroupName) ($($Project.Maps.Count))"
    Write-Host "  Selecting it opens $($Project.Maps.Count) child map location(s)."
    Write-Host "  SHA-256: $hash"

    return [PSCustomObject]@{
        OutputRoot = $Project.Root
        FinalBig = $finalBig
        RecompTree = $groupRecompRoot
        ContentId = $groupContentId
        PackageName = $groupPackageName
        DisplayName = $Project.GroupName
        LegacyContentId = $legacyGroupContentId
        MemberMaps = @($Project.Maps)
        Sha256 = $hash
        MapCount = $Project.Maps.Count
    }
}

function Set-BigEndianUInt32([byte[]]$Bytes, [int]$Offset, [uint32]$Value) {
    $Bytes[$Offset + 0] = [byte](($Value -shr 24) -band 0xFF)
    $Bytes[$Offset + 1] = [byte](($Value -shr 16) -band 0xFF)
    $Bytes[$Offset + 2] = [byte](($Value -shr 8) -band 0xFF)
    $Bytes[$Offset + 3] = [byte]($Value -band 0xFF)
}

function Write-XboxContentHeader([string]$Path, [string]$Id, [string]$Name) {
    $bytes = New-Object byte[] 0x148
    Set-BigEndianUInt32 $bytes 0x00 ([uint32]1)
    Set-BigEndianUInt32 $bytes 0x04 ([uint32]2)

    $disp = $Name
    if ($disp.Length -gt 127) { $disp = $disp.Substring(0, 127) }
    $dispBytes = [System.Text.Encoding]::BigEndianUnicode.GetBytes($disp)
    [System.Array]::Copy($dispBytes, 0, $bytes, 0x08, [Math]::Min($dispBytes.Length, 0x100))

    $fileName = $Id
    if ($fileName.Length -gt 41) { $fileName = $fileName.Substring(0, 41) }
    $fileBytes = [System.Text.Encoding]::ASCII.GetBytes($fileName)
    [System.Array]::Copy($fileBytes, 0, $bytes, 0x108, $fileBytes.Length)

    Set-BigEndianUInt32 $bytes 0x13C ([Convert]::ToUInt32("454108E6", 16))

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Resolve-Skate3UserDataRoot([string]$ExeRoot) {
    if (Test-Path (Join-Path $ExeRoot "portable.txt")) { return $ExeRoot }
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        Fail "APPDATA is unavailable, so the Skate3Recomp content root cannot be resolved."
    }
    return (Join-Path $env:APPDATA "skate3")
}

function Remove-RecompContentRegistration([string]$TitleRoot, [string]$ContentId) {
    if ([string]::IsNullOrWhiteSpace($ContentId)) { return }
    $contentDir = Join-Path $TitleRoot "$MarketplaceType\$ContentId"
    $headerPath = Join-Path $TitleRoot "Headers\$MarketplaceType\$ContentId.header"
    if (Test-Path -LiteralPath $contentDir) {
        Remove-Item -LiteralPath $contentDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  removed old content: $ContentId" -ForegroundColor DarkGray
    }
    if (Test-Path -LiteralPath $headerPath) {
        Remove-Item -LiteralPath $headerPath -Force -ErrorAction SilentlyContinue
    }
}

function Install-MapToRecomp(
    [string]$ReleaseRoot,
    [string]$BigPath,
    [string]$PackageName,
    [string]$ContentId,
    [string]$MapName,
    [string[]]$PurgeContentIds = @()
) {
    $root = $ReleaseRoot.Trim().Trim('"')
    if ($root.EndsWith("skate3.exe", [System.StringComparison]::OrdinalIgnoreCase)) { $root = Split-Path -Parent $root }
    $exe = Join-Path $root "skate3.exe"
    if (-not (Test-Path $exe)) { Fail "That folder does not contain skate3.exe: $root" }
    if (Get-Process -Name "skate3" -ErrorAction SilentlyContinue) { Fail "Close Skate3Recomp before installing the converted map." }

    $userRoot = Resolve-Skate3UserDataRoot $root
    $titleRoot = Join-Path $userRoot "$SharedXuid\$TitleId"

    # Group migration: remove the v1.07 group registration and the standalone
    # map registrations being replaced by this one parent package. Never purge
    # the ContentID we are about to install.
    $purge = @($PurgeContentIds | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_ -ine $ContentId
    } | Select-Object -Unique)
    if ($purge.Count -gt 0) {
        Write-Host ""
        Write-Host "Collapsing standalone map entries into the grouped parent..." -ForegroundColor Cyan
        foreach ($oldId in $purge) { Remove-RecompContentRegistration $titleRoot ([string]$oldId) }
    }

    # Replace the destination registration atomically enough for the content
    # enumerator: remove any previous copy, then write BIG + matching header.
    Remove-RecompContentRegistration $titleRoot $ContentId
    $contentDir = Join-Path $titleRoot "$MarketplaceType\$ContentId"
    $headerPath = Join-Path $titleRoot "Headers\$MarketplaceType\$ContentId.header"
    $installedBig = Join-Path $contentDir $PackageName

    New-Item -ItemType Directory -Force -Path $contentDir | Out-Null
    Copy-Item -LiteralPath $BigPath -Destination $installedBig -Force
    Write-XboxContentHeader $headerPath $ContentId $MapName

    Write-Host ""
    Write-Host "Installed to Skate3Recomp:" -ForegroundColor Green
    Write-Host "  $installedBig"
    Write-Host "  $headerPath"
    if ($purge.Count -gt 0) {
        Write-Host "  Group migration removed $($purge.Count) old standalone/legacy registration(s)." -ForegroundColor Green
    }
}

function Apply-XboxConverterFixes([string]$ConverterRoot, [string]$BuilderRoot) {
    $boundsPatch = Join-Path $Here "ConverterPatch\XboxRenderModelBoundsFix.cs"
    $materialPatch = Join-Path $Here "ConverterPatch\XboxRenderMaterialPlatformFix.cs"
    $groupPatch = Join-Path $Here "ConverterPatch\ImporterGroupCommand.cs"
    foreach ($required in @($boundsPatch, $materialPatch, $groupPatch)) {
        if (-not (Test-Path $required)) { Fail "Bundled converter patch is missing: $required" }
    }

    $transcodeDir = Join-Path $ConverterRoot "src\Sk3.Transcode"
    $transcoderPath = Join-Path $transcodeDir "ArenaTranscoder.cs"
    if (-not (Test-Path $transcoderPath)) { Fail "Converter source is missing: $transcoderPath" }

    Copy-Item -LiteralPath $boundsPatch -Destination (Join-Path $transcodeDir "XboxRenderModelBoundsFix.cs") -Force
    Copy-Item -LiteralPath $materialPatch -Destination (Join-Path $transcodeDir "XboxRenderMaterialPlatformFix.cs") -Force

    $source = ([System.IO.File]::ReadAllText($transcoderPath)).Replace("`r`n", "`n")

    # Insert RenderModelData radius repair if it is not already present.
    if (-not $source.Contains("XboxRenderModelBoundsFix.Apply(o.Data)")) {
        $anchor = "                MeshObjectConverters.RenderOptiMeshType =>`n                    MeshObjectConverters.ConvertRenderOptiMesh(o.Data),"
        $replacement = $anchor + "`n                XboxRenderModelBoundsFix.RenderModelDataType =>`n                    XboxRenderModelBoundsFix.Apply(o.Data),"
        if (-not $source.Contains($anchor)) {
            Fail "Pinned converter no longer matches the expected RenderOptiMesh block; refusing an unsafe bounds patch."
        }
        $source = $source.Replace($anchor, $replacement)
    }

    # RenderMaterialData otherwise crosses unchanged. Remap the known PS3-only
    # environment.default macro-overlay GUID/stream to the X360 resource.
    if (-not $source.Contains("XboxRenderMaterialPlatformFix.Apply(o.Data)")) {
        $anchor = "                XboxRenderModelBoundsFix.RenderModelDataType =>`n                    XboxRenderModelBoundsFix.Apply(o.Data),"
        if (-not $source.Contains($anchor)) {
            Fail "Could not locate the RenderModelData patch anchor for the Xbox material remap."
        }
        $replacement = $anchor + "`n                XboxRenderMaterialPlatformFix.RenderMaterialDataType =>`n                    XboxRenderMaterialPlatformFix.Apply(o.Data),"
        $source = $source.Replace($anchor, $replacement)
    }

    # Selective referenced-lightmap repair can target a real authored lightmap
    # regardless of mip count. This only matters when flatGray=true for an asset
    # explicitly selected by the material scan; normal conversion is unchanged.
    $oldLightmapClassify = "        bool lightmap = !info.IsCubemap && info.MipCount <= 1 && (lightmapTile || GrayEveryTexture);"
    $newLightmapClassify = "        bool lightmap = !info.IsCubemap && (lightmapTile || GrayEveryTexture);"
    if ($source.Contains($oldLightmapClassify)) {
        $source = $source.Replace($oldLightmapClassify, $newLightmapClassify)
    } elseif (-not $source.Contains($newLightmapClassify)) {
        Fail "Pinned ArenaTranscoder no longer matches the expected lightmap classification block."
    }

    [System.IO.File]::WriteAllText($transcoderPath, $source, (New-Object System.Text.UTF8Encoding($false)))

    # Full rebuild: keep the neutral packer's proven stride-32/FLOAT2 UV bytes
    # instead of widening them back to the broken stride-36 path.
    $meshConverter = Join-Path $ConverterRoot "src\Sk3.Transcode\MeshObjectConverters.cs"
    if (-not (Test-Path $meshConverter)) { Fail "Converter MeshObjectConverters.cs is missing." }
    $meshSource = ([System.IO.File]::ReadAllText($meshConverter)).Replace("`r`n", "`n")
    $oldReturn = "        return new RebuiltMesh(WidenUvToFloat3(packed),`n                               XboxMesh.VertexDescriptorBuilder.BuildStaticMeshLayout());"
    $newReturn = "        return new RebuiltMesh(packed,`n                               XboxMesh.VertexDescriptorBuilder.BuildStaticMeshLayout());"
    if ($meshSource.Contains($oldReturn)) {
        $meshSource = $meshSource.Replace($oldReturn, $newReturn)
        [System.IO.File]::WriteAllText($meshConverter, $meshSource, (New-Object System.Text.UTF8Encoding($false)))
    } elseif (-not $meshSource.Contains("return new RebuiltMesh(packed,")) {
        Fail "Pinned converter no longer matches the expected UV widening block; refusing an unsafe UV patch."
    }

    $descriptor = Join-Path $BuilderRoot "ArenaBuilder Modular\src\ArenaBuilder.Core\Platforms\Xbox\Pegasus\Mesh\VertexDescriptorBuilder.cs"
    if (-not (Test-Path $descriptor)) { Fail "Xbox VertexDescriptorBuilder.cs is missing." }
    $vd = ([System.IO.File]::ReadAllText($descriptor)).Replace("`r`n", "`n")

    $oldBlock = @'
        const byte stride = 36;
        var elements = new[]
        {
            new Element(0, 0,  XboxVertexFormat.FLOAT3,  0, XboxDeclUsage.POSITION, 0, 1),   // Position @0
            new Element(0, 12, XboxVertexFormat.FLOAT3,  0, XboxDeclUsage.TEXCOORD, 0, 6),   // TEX0 diffuse UV FLOAT3 (U,V,0) @12
            new Element(0, 24, Tex1LmNorm,               0, XboxDeclUsage.TEXCOORD, 1, 7),   // TEX1 lm_norm i16x4 @24
            new Element(0, 32, XboxVertexFormat.DEC3N_V, 0, XboxDeclUsage.TANGENT,  0, 21),  // Tangent dec3n @32
        };
'@
    $newBlock = @'
        const byte stride = 32;
        var elements = new[]
        {
            new Element(0, 0,  XboxVertexFormat.FLOAT3, 0, XboxDeclUsage.POSITION, 0, 1),   // Position @0
            new Element(0, 12, Tex0Float2,              0, XboxDeclUsage.TEXCOORD, 0, 6),   // TEX0 diffuse UV FLOAT2 @12
            new Element(0, 20, Tex1LmNorm,              0, XboxDeclUsage.TEXCOORD, 1, 7),   // TEX1 lm_norm i16x4 @20
            new Element(0, 28, XboxVertexFormat.DEC3N_V,0, XboxDeclUsage.TANGENT,  0, 21),  // Tangent dec3n @28
        };
'@

    if ($vd.Contains($oldBlock)) {
        $vd = $vd.Replace($oldBlock, $newBlock)
        [System.IO.File]::WriteAllText($descriptor, $vd, (New-Object System.Text.UTF8Encoding($false)))
    } elseif (-not ($vd.Contains("const byte stride = 32;") -and $vd.Contains("new Element(0, 12, Tex0Float2") -and $vd.Contains("new Element(0, 20, Tex1LmNorm") -and $vd.Contains("new Element(0, 28, XboxVertexFormat.DEC3N_V"))) {
        Fail "Pinned Xbox builder no longer matches the expected FLOAT3/stride-36 block; refusing an unsafe UV patch."
    }

    # v1.13 texture safety:
    #  1) normal conversion must preserve authored black textures exactly;
    #  2) the OPTIONAL baked-light repair must not synthesize whole DXT blocks.
    #     The old FlatGray path overwrote DXT3/DXT5 alpha/mask bytes and DXT1
    #     transparency mode. Some custom maps need their bad cTex lighting
    #     neutralized, but hang forever if those structural/mask bits are lost.
    #     The safe repair below changes RGB endpoints only while preserving the
    #     original block count, selectors, alpha bytes and DXT1 alpha mode.
    $textureConverter = Join-Path $ConverterRoot "src\Sk3.Transcode\TextureObjectConverter.cs"
    if (-not (Test-Path $textureConverter)) { Fail "Converter TextureObjectConverter.cs is missing." }
    $texSource = ([System.IO.File]::ReadAllText($textureConverter)).Replace("`r`n", "`n")
    $oldAutoBlackRepair = "        if (flatGray || IsAllBlack(info.Format, linearPayload))`n            linearPayload = FlatGray(info, linearPayload.Length);"
    $v112ExplicitRepair = "        if (flatGray)`n            linearPayload = FlatGray(info, linearPayload.Length);"
    $safeExplicitRepair = "        if (flatGray)`n            linearPayload = NeutralizeLightmapRgbPreserveStructure(info, linearPayload);"
    if ($texSource.Contains($oldAutoBlackRepair)) {
        $texSource = $texSource.Replace($oldAutoBlackRepair, $safeExplicitRepair)
    } elseif ($texSource.Contains($v112ExplicitRepair)) {
        $texSource = $texSource.Replace($v112ExplicitRepair, $safeExplicitRepair)
    } elseif (-not $texSource.Contains($safeExplicitRepair)) {
        Fail "Pinned TextureObjectConverter no longer matches the expected texture-repair call site."
    }

    if (-not $texSource.Contains("NeutralizeLightmapRgbPreserveStructure" + "(Ps3TextureInfo info, byte[] source)")) {
        $flatGrayAnchor = "    public static byte[] FlatGray(Ps3TextureInfo info, int length)"
        if (-not $texSource.Contains($flatGrayAnchor)) {
            Fail "Pinned TextureObjectConverter no longer contains the FlatGray anchor for the safe cTex repair patch."
        }
        $safeMethod = @'
    /// <summary>
    /// Neutralizes baked-light RGB while preserving every structural/mask bit of the source DXT blocks.
    /// DXT3/DXT5 alpha bytes, color selectors and DXT1 transparency mode are all retained.
    /// </summary>
    public static byte[] NeutralizeLightmapRgbPreserveStructure(Ps3TextureInfo info, byte[] source)
    {
        const ushort GreyLo = 0x8410;
        const ushort GreyHi = 0x8411;
        int bytesPerBlock = BytesPerBlock(info.Format);
        int colour = bytesPerBlock - 8;
        var payload = (byte[])source.Clone();

        for (int at = 0; at + bytesPerBlock <= payload.Length; at += bytesPerBlock)
        {
            int c = at + colour;
            ushort old0 = BinaryPrimitives.ReadUInt16LittleEndian(payload.AsSpan(c, 2));
            ushort old1 = BinaryPrimitives.ReadUInt16LittleEndian(payload.AsSpan(c + 2, 2));

            // BC1/DXT1 uses endpoint ordering to select four-colour vs 1-bit-alpha mode.
            // Preserve that ordering so a lightmap page cannot accidentally become opaque
            // (or transparent) just because its lighting RGB was neutralized.
            ushort new0, new1;
            if (bytesPerBlock == 8 && old0 <= old1)
            {
                new0 = GreyLo;
                new1 = GreyHi;
            }
            else
            {
                new0 = GreyHi;
                new1 = GreyLo;
            }

            BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(c, 2), new0);
            BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(c + 2, 2), new1);
            // Deliberately keep the existing selector bytes and, for DXT3/DXT5,
            // the first eight alpha bytes unchanged.
        }
        return payload;
    }

'@
        $texSource = $texSource.Replace($flatGrayAnchor, $safeMethod + $flatGrayAnchor)
    }
    [System.IO.File]::WriteAllText($textureConverter, $texSource, (New-Object System.Text.UTF8Encoding($false)))

    # v1.16: do not rewrite material lightmap GUIDs. Instead scan the PS3
    # RenderMaterialData first, collect the exact GUIDs used by lightmap channels,
    # then neutralize only matching texture assets as they are converted.
    $distConverter = Join-Path $ConverterRoot "src\Sk3.Transcode\DistConverter.cs"
    if (-not (Test-Path $distConverter)) { Fail "Converter DistConverter.cs is missing." }
    $distSource = ([System.IO.File]::ReadAllText($distConverter)).Replace("`r`n", "`n")

    $scanAnchor = "        int arenas = 0, streams = 0;"
    $scanBlock = @'
        int arenas = 0, streams = 0;
        XboxRenderMaterialPlatformFix.PrepareSelectiveLightmapRepair(ps3Dist);
        int selectivelyNeutralizedLightmaps = 0;
'@
    if ($distSource.Contains($scanAnchor) -and -not $distSource.Contains("PrepareSelectiveLightmapRepair(ps3Dist)")) {
        $distSource = $distSource.Replace($scanAnchor, $scanBlock.TrimEnd())
    } elseif (-not $distSource.Contains("PrepareSelectiveLightmapRepair(ps3Dist)")) {
        Fail "Pinned DistConverter no longer matches the expected conversion counter block."
    }

    $oldArenaConvert = @'
                    var arena = ArenaTranscoder.ToXbox360(asset.Arena, mode, grayLightmaps,
                                                          lightmapTile).Arena;
                    converted.Add(new StreamAsset(asset.AssetId, arena));
                    arenas++;
'@
    $newArenaConvert = @'
                    bool selectiveLightmap = XboxRenderMaterialPlatformFix.ShouldNeutralizeLightmapAsset(asset.AssetId);
                    var arena = ArenaTranscoder.ToXbox360(asset.Arena, mode,
                                                          grayLightmaps || selectiveLightmap,
                                                          lightmapTile || selectiveLightmap).Arena;
                    converted.Add(new StreamAsset(asset.AssetId, arena));
                    if (selectiveLightmap) selectivelyNeutralizedLightmaps++;
                    arenas++;
'@
    if ($distSource.Contains($oldArenaConvert)) {
        $distSource = $distSource.Replace($oldArenaConvert, $newArenaConvert)
    } elseif (-not $distSource.Contains("ShouldNeutralizeLightmapAsset(asset.AssetId)")) {
        Fail "Pinned DistConverter no longer matches the expected ArenaTranscoder call block."
    }

    $returnAnchor = "        CopySidecars(ps3Dist, outputDir, sourceName, distName, log);`n        return new DistResult(streams, arenas, refused, manifests);"
    $returnPatch = @'
        CopySidecars(ps3Dist, outputDir, sourceName, distName, log);
        if (selectivelyNeutralizedLightmaps > 0)
            log?.Invoke($"  selectively neutralized {selectivelyNeutralizedLightmaps} material-referenced lightmap texture asset(s)");
        return new DistResult(streams, arenas, refused, manifests);
'@
    if ($distSource.Contains($returnAnchor)) {
        $distSource = $distSource.Replace($returnAnchor, $returnPatch)
    } elseif (-not $distSource.Contains("selectively neutralized {selectivelyNeutralizedLightmaps}")) {
        Fail "Pinned DistConverter no longer matches the expected return block."
    }
    [System.IO.File]::WriteAllText($distConverter, $distSource, (New-Object System.Text.UTF8Encoding($false)))

    # Add the importer-only grouped-locations command to Sk3.Cli. The DlcBuilder
    # already supports PackageInput.Maps; this small command exposes it to the
    # PowerShell GUI without forking the builder.
    $cliDir = Join-Path $ConverterRoot "src\Sk3.Cli"
    $programPath = Join-Path $cliDir "Program.cs"
    if (-not (Test-Path $programPath)) { Fail "Converter CLI Program.cs is missing." }
    Copy-Item -LiteralPath $groupPatch -Destination (Join-Path $cliDir "ImporterGroupCommand.cs") -Force

    $program = ([System.IO.File]::ReadAllText($programPath)).Replace("`r`n", "`n")
    if (-not $program.Contains('"build-group-staging" => ImporterGroupCommand.Run(args[1])')) {
        $anchor = '        "pack-staging" => PackStagingTree(args[1], args[2],'
        if (-not $program.Contains($anchor)) {
            Fail "Pinned converter CLI no longer matches the expected pack-staging switch block."
        }
        $program = $program.Replace($anchor,
            '        "build-group-staging" => ImporterGroupCommand.Run(args[1]),' + "`n" + $anchor)
        [System.IO.File]::WriteAllText($programPath, $program, (New-Object System.Text.UTF8Encoding($false)))
    }

    Write-Host "Applied Xbox conversion fixes: full mesh rebuild UV layout + RenderModel bounds + X360 material GUID remap + optional macro-overlay suppression + selective material-referenced lightmap texture repair + lossless default textures + grouped Locations helper." -ForegroundColor Green
}

function Write-ToolchainMarker {
    $markerText = @"
Skate3 PS3-to-X360 Map Importer patched toolchain cache v$ToolchainCacheVersion
Importer=$ImporterVersion
Converter=$ConverterCommit
External=$ExternalCommit
MESH_REBUILD=1
RENDER_BOUNDS_FIX=1
UV_FLOAT2_STRIDE32_FIX=1
MATERIAL_PLATFORM_GUID_FIX=1
GROUP_STAGING_HELPER=1
AUTO_BLACK_TEXTURE_REPAIR_DISABLED=1
SAFE_CTEXT_RGB_ONLY_REPAIR=1
SECONDARY_MACRO_OVERLAY_REPAIR=1
SELECTIVE_REFERENCED_LIGHTMAP_REPAIR=1
"@
    Set-Content -LiteralPath $ToolchainMarker -Value $markerText -Encoding ASCII
}

function Prepare-Toolchain {
    New-Item -ItemType Directory -Force -Path $CacheRoot, $WorkingRoot | Out-Null
    $git = Ensure-Git
    $dotnet = Ensure-DotNet9

    $markerExists = Test-Path $ToolchainMarker
    $markerText = if ($markerExists) { Get-Content -LiteralPath $ToolchainMarker -Raw -ErrorAction SilentlyContinue } else { "" }
    $sourceReposReady = (Test-Path (Join-Path $ToolRoot ".git")) -and (Test-Path (Join-Path $ExternalRoot ".git"))
    $needsV105Upgrade = $markerExists -and (
        $markerText -notmatch '(?m)^MATERIAL_PLATFORM_GUID_FIX=1$' -or
        $markerText -notmatch '(?m)^GROUP_STAGING_HELPER=1$' -or
        $markerText -notmatch '(?m)^AUTO_BLACK_TEXTURE_REPAIR_DISABLED=1$' -or
        $markerText -notmatch '(?m)^SAFE_CTEXT_RGB_ONLY_REPAIR=1$' -or
        $markerText -notmatch '(?m)^SECONDARY_MACRO_OVERLAY_REPAIR=1$' -or
        $markerText -notmatch '(?m)^SELECTIVE_REFERENCED_LIGHTMAP_REPAIR=1$'
    )

    if ($ForceToolchainRefresh) {
        $markerExists = $false
        $needsV105Upgrade = $false
    }

    if ($needsV105Upgrade -and $sourceReposReady) {
        Write-Host ""
        Write-Host "Upgrading the existing cached converter with v1.16 selective referenced-lightmap compatibility repair..." -ForegroundColor Cyan
        # Start this upgrade from the pinned clean sources. Earlier importer
        # versions patched the shared cache in place, so a hard checkout avoids
        # carrying stale material/lightmap experiments into v1.16.
        Run-Checked $git @("-C", $ToolRoot, "fetch", "--no-tags", "origin", $ConverterCommit) "Refreshing converter revision"
        Run-Checked $git @("-C", $ToolRoot, "checkout", "--force", $ConverterCommit) "Resetting converter to pinned revision"
        Run-Checked $git @("-C", $ExternalRoot, "fetch", "--no-tags", "origin", $ExternalCommit) "Refreshing DLC-builder revision"
        Run-Checked $git @("-C", $ExternalRoot, "checkout", "--force", $ExternalCommit) "Resetting DLC builder to pinned revision"
        Apply-XboxConverterFixes $ToolRoot $ExternalRoot
        $cliProject = Join-Path $ToolRoot "src\Sk3.Cli\Sk3.Cli.csproj"
        Run-Checked $dotnet @("build", $cliProject, "-c", "Release", "-v", "minimal") "Upgrading PS3-to-X360 converter"
        Write-ToolchainMarker
        $markerExists = $true
    }
    elseif (-not $markerExists) {
        Write-Host ""
        Write-Host "Preparing pinned PS3 -> Xbox 360 conversion toolchain..." -ForegroundColor Cyan

        if (-not (Test-Path (Join-Path $ToolRoot ".git"))) {
            if (Test-Path $ToolRoot) { Remove-Item -LiteralPath $ToolRoot -Recurse -Force }
            Run-Checked $git @("clone", "--no-tags", $ConverterUrl, $ToolRoot) "Cloning skate3-ps3-to-x360"
        }
        Run-Checked $git @("-C", $ToolRoot, "fetch", "--no-tags", "origin", $ConverterCommit) "Fetching converter revision"
        Run-Checked $git @("-C", $ToolRoot, "checkout", "--force", $ConverterCommit) "Checking out converter revision"

        if (-not (Test-Path (Join-Path $ExternalRoot ".git"))) {
            $parent = Split-Path -Parent $ExternalRoot
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
            if (Test-Path $ExternalRoot) { Remove-Item -LiteralPath $ExternalRoot -Recurse -Force }
            Run-Checked $git @("clone", "--no-tags", $ExternalUrl, $ExternalRoot) "Cloning Xbox/DLC builder tools"
        }
        Run-Checked $git @("-C", $ExternalRoot, "fetch", "--no-tags", "origin", $ExternalCommit) "Fetching DLC-builder revision"
        Run-Checked $git @("-C", $ExternalRoot, "checkout", "--force", $ExternalCommit) "Checking out DLC-builder revision"

        Apply-XboxConverterFixes $ToolRoot $ExternalRoot

        $cliProject = Join-Path $ToolRoot "src\Sk3.Cli\Sk3.Cli.csproj"
        Write-Host "Building converter..." -ForegroundColor Cyan
        Run-Checked $dotnet @("build", $cliProject, "-c", "Release", "-v", "minimal") "Building PS3-to-X360 converter"
        Write-ToolchainMarker
    }
    else {
        Write-Host "Using cached patched PS3 -> Xbox 360 toolchain." -ForegroundColor Green
    }

    $cliDll = Join-Path $ToolRoot "src\Sk3.Cli\bin\Release\net9.0\Sk3.Cli.dll"
    if (-not (Test-Path $cliDll)) {
        Remove-Item -LiteralPath $ToolchainMarker -Force -ErrorAction SilentlyContinue
        Fail "Cached toolchain marker exists but Sk3.Cli.dll is missing. Run again with Force toolchain refresh."
    }

    $bigFileExe = Get-ChildItem -LiteralPath $ExternalRoot -Filter "bigfile.exe" -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bigFileExe) { Fail "EA bigfile.exe was not found in the pinned DLC-builder tools." }

    return [PSCustomObject]@{
        Git = $git
        DotNet = $dotnet
        CliDll = $cliDll
        CliBinDir = Split-Path -Parent $cliDll
        BigFileExe = $bigFileExe.FullName
    }
}

# v1.13 maintenance mode used by the GUI DLC Map Manager. This rebuilds an
# existing saved parent Location project without reconverting any PS3 source map.
# The group project already points at persistent converted X360 DIST folders.
if (-not [string]::IsNullOrWhiteSpace($RebuildGroupProject)) {
    $projectPath = $RebuildGroupProject.Trim().Trim('"')
    if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
        Fail "Saved Location Group project does not exist: $projectPath"
    }

    try {
        $cfg = Get-Content -LiteralPath $projectPath -Raw | ConvertFrom-Json
    } catch {
        Fail "Could not read saved Location Group project: $projectPath"
    }
    $maps = if ($cfg.Maps) { @($cfg.Maps) } else { @() }
    if ($maps.Count -eq 0) { Fail "Saved Location Group has no maps to rebuild." }

    $groupNameForRebuild = if ($cfg.GroupName) { [string]$cfg.GroupName } else { Split-Path -Leaf (Split-Path -Parent $projectPath) }
    $groupSlugForRebuild = if ($cfg.GroupSlug) { [string]$cfg.GroupSlug } else { Make-Slug $groupNameForRebuild }
    $groupRootForRebuild = Split-Path -Parent $projectPath
    $project = [PSCustomObject]@{
        Root = $groupRootForRebuild
        ProjectPath = $projectPath
        GroupName = $groupNameForRebuild
        GroupSlug = $groupSlugForRebuild
        Maps = $maps
    }

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " Skate 3 PS3 -> Xbox 360 Map Importer v$ImporterVersion"
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Maintenance mode: rebuilding saved Location parent '$groupNameForRebuild' with $($maps.Count) child map(s)." -ForegroundColor Green

    $sessionId = [Guid]::NewGuid().ToString("N")
    $sessionRoot = Join-Path $WorkingRoot $sessionId
    New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
    try {
        $tools = Prepare-Toolchain
        $stagingData = Join-Path $tools.CliBinDir "data"
        $groupResult = Build-LocationGroupPackage $project $tools $stagingData $sessionRoot ([bool]$KeepStaging)

        if ($InstallToRecomp) {
            if ([string]::IsNullOrWhiteSpace($RecompDir)) {
                if ($NonInteractive) { Fail "RecompDir is required when rebuilding/installing a saved parent non-interactively." }
                $RecompDir = Select-Folder "Select Skate3Recomp folder containing skate3.exe"
                if ([string]::IsNullOrWhiteSpace($RecompDir)) { $RecompDir = Read-Host "Paste Skate3Recomp folder containing skate3.exe" }
            }

            $purgeIds = New-Object System.Collections.Generic.List[string]
            if ($groupResult.LegacyContentId) { $purgeIds.Add([string]$groupResult.LegacyContentId) }
            foreach ($gm in @($project.Maps)) {
                if ($gm.StandaloneContentId) { $purgeIds.Add([string]$gm.StandaloneContentId) }
                elseif ($gm.DisplayName) { $purgeIds.Add((Make-ContentId ([string]$gm.DisplayName))) }
                if ($gm.StandaloneProductId) { $purgeIds.Add([string]$gm.StandaloneProductId) }
            }
            Install-MapToRecomp $RecompDir $groupResult.FinalBig $groupResult.PackageName $groupResult.ContentId $groupResult.DisplayName @($purgeIds | Select-Object -Unique)
        }

        Write-Host ""
        Write-Host "SAVED LOCATION GROUP REBUILD COMPLETE" -ForegroundColor Green
        Write-Host "  Parent: $groupNameForRebuild ($($maps.Count))"
        Write-Host "  BIG   : $($groupResult.FinalBig)"
        exit 0
    }
    finally {
        if (Test-Path -LiteralPath $sessionRoot) { Remove-Item -LiteralPath $sessionRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Skate 3 PS3 -> Xbox 360 Map Importer v$ImporterVersion"
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Converts PS3 DIST_* maps into Xbox 360-native Skate 3 data." -ForegroundColor Green
Write-Host "Uses full vertex reconstruction, Xbox RenderModel bounds repair,"
Write-Host "the working FLOAT2/stride-32 UV layout, PS3->X360 material GUID remapping, and optional selective referenced-lightmap repair."
Write-Host ""

if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Select-ArchiveOrFolder
}
if ([string]::IsNullOrWhiteSpace($SourcePath)) { Fail "No PS3 map source was selected." }
$SourcePath = $SourcePath.Trim().Trim('"')
if (-not (Test-Path $SourcePath)) { Fail "Source does not exist: $SourcePath" }
$SourcePath = (Resolve-Path $SourcePath).Path

$sessionId = [Guid]::NewGuid().ToString("N")
$sessionRoot = Join-Path $WorkingRoot $sessionId
New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null

try {
    $sourceRoot = $SourcePath
    if (Test-Path $SourcePath -PathType Leaf) {
        $ext = [System.IO.Path]::GetExtension($SourcePath).ToLowerInvariant()
        $extractRoot = Join-Path $sessionRoot "extracted"
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

        Write-Host "Extracting map archive..." -ForegroundColor Cyan
        if ($ext -notin @(".zip", ".rar", ".7z")) {
            Fail "Unsupported archive type '$ext'. Supported: .rar, .zip, .7z, or an extracted folder."
        }
        Expand-MapArchive $SourcePath $extractRoot
        $sourceRoot = $extractRoot
    }

    Write-Host "Scanning source recursively for PS3 DIST folders..." -ForegroundColor Cyan
    $candidates = @(Find-DistFolders $sourceRoot)
    if ($candidates.Count -eq 0) {
        # Also inspect archives nested under a selected parent folder, not just
        # archives nested inside another archive. This covers release folders
        # shaped like AuthorPack\MapName\actual-map.rar.
        Expand-NestedMapArchives $sourceRoot $sessionRoot 2
        $candidates = @(Find-DistFolders $sourceRoot)
    }
    if ($candidates.Count -gt 0) {
        Write-Host "Found $($candidates.Count) usable DIST candidate(s) recursively." -ForegroundColor DarkGray
    }
    $mapDir = Select-DistFolder $candidates $DistName
    if ([string]::IsNullOrWhiteSpace($mapDir)) { Fail "No usable PS3 DIST map was found in the selected source." }

    $sourceWorldId = Resolve-Ps3WorldId $mapDir
    Validate-Ps3Dist $mapDir $sourceWorldId
    $mapDir = Normalize-SourceDistFolder $mapDir $sourceWorldId $sessionRoot

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $defaultName = ($sourceWorldId -replace '^DIST_', '') -replace '_', ' '
        $typedName = Read-Host "Map display name [$defaultName]"
        $DisplayName = if ([string]::IsNullOrWhiteSpace($typedName)) { $defaultName } else { $typedName.Trim() }
    }

    $worldId = Make-TargetWorldId $DisplayName
    $slug = Make-Slug $DisplayName
    $contentId = Make-ContentId $DisplayName
    $packageName = "${slug}_00000000.big"

    if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
        $documents = [Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments)
        $defaultOutput = Join-Path $documents "Skate3-X360-Converted-Maps"
        $picked = Select-Folder "Select output folder for converted Xbox 360 maps (Cancel = $defaultOutput)"
        $OutputRoot = if ([string]::IsNullOrWhiteSpace($picked)) { $defaultOutput } else { $picked }
    }
    $OutputRoot = [System.IO.Path]::GetFullPath($OutputRoot.Trim().Trim('"'))
    $mapOutput = Join-Path $OutputRoot $slug
    $dlcOutputDir = Join-Path $mapOutput "DLC"
    $x360DistRoot = Join-Path $mapOutput "X360-DIST"
    $recompTreeRoot = Join-Path $mapOutput "Recomp-Content"
    $logsDir = Join-Path $mapOutput "Logs"
    New-Item -ItemType Directory -Force -Path $mapOutput, $dlcOutputDir, $logsDir | Out-Null

    Write-Host ""
    Write-Host "PS3 map detected:" -ForegroundColor White
    Write-Host "  Source World : $sourceWorldId"
    Write-Host "  Xbox World   : $worldId"
    Write-Host "  Name         : $DisplayName"
    Write-Host "  Source       : $mapDir"
    Write-Host "  Spawn    : $SpawnX,$SpawnY,$SpawnZ,$SpawnYaw"
    Write-Host "  Output   : $mapOutput"
    if (-not [string]::IsNullOrWhiteSpace($GroupName)) {
        Write-Host "  Group    : $GroupName (this map will be added/updated in one grouped Locations package)"
    }
    if ($NeutralizeLightmaps -or $BypassBakedLightmaps) {
        Write-Host "  Texture repair: SELECTIVE material-referenced lightmap neutralization enabled; bindings/alpha/masks preserved." -ForegroundColor Yellow
    } else {
        Write-Host "  Texture mode: lossless authored PS3 payloads; selective lightmap repair OFF"
    }
    if ($SuppressMacroOverlay) {
        Write-Host "  Material repair: repeating environment.default macro-overlay DISABLED; diffuse/normal/cTex preserved." -ForegroundColor Yellow
    }
    if ($BypassBakedLightmaps) {
        Write-Host "  Legacy material lightmap binding bypass requested; v1.16 ignores it and uses selective texture repair instead." -ForegroundColor Yellow
    }
    Write-Host ""

    $tools = Prepare-Toolchain
    $cliDll = $tools.CliDll
    $cliBinDir = $tools.CliBinDir
    $dotnet = $tools.DotNet

    $stagingData = Join-Path $cliBinDir "data"
    Remove-Item -LiteralPath $stagingData -Recurse -Force -ErrorAction SilentlyContinue

    $temporaryBig = Join-Path $sessionRoot "converter-output.big"
    $buildLog = Join-Path $logsDir "build-dlc.log"
    $spawnArg = "--spawn=$SpawnX,$SpawnY,$SpawnZ,$SpawnYaw"

    Write-Host "Converting PS3 map to Xbox 360..." -ForegroundColor Cyan
    $env:SK3_REFUSED_DETAIL = "1"
    $convertArgs = @(
        $cliDll,
        "build-dlc",
        $mapDir,
        $temporaryBig,
        "--name=$DisplayName",
        "--dist=$worldId",
        $spawnArg,
        "--rebuild-vertices"
    )
    if ($NeutralizeLightmaps -or $BypassBakedLightmaps) {
        $env:SK3_IMPORTER_SELECTIVE_LIGHTMAP_REPAIR = "1"
        Write-Host "  texture compatibility: selective material-referenced lightmap repair enabled; resource bindings remain unchanged" -ForegroundColor Yellow
    } else {
        Remove-Item Env:SK3_IMPORTER_SELECTIVE_LIGHTMAP_REPAIR -ErrorAction SilentlyContinue
        Write-Host "  texture compatibility: preserving authored texture payloads exactly; selective lightmap repair OFF" -ForegroundColor DarkGray
    }
    if ($SuppressMacroOverlay) {
        $env:SK3_IMPORTER_SUPPRESS_MACRO_OVERLAY = "1"
        Write-Host "  material compatibility: suppressing repeating macro-overlay contribution only" -ForegroundColor Yellow
    } else {
        Remove-Item Env:SK3_IMPORTER_SUPPRESS_MACRO_OVERLAY -ErrorAction SilentlyContinue
    }
    if ($BypassBakedLightmaps) {
        Write-Host "  compatibility note: legacy -BypassBakedLightmaps now aliases the safer selective referenced-lightmap repair." -ForegroundColor DarkYellow
    }
    try {
        Run-LoggedChecked $dotnet $convertArgs "PS3-to-Xbox 360 map conversion" $buildLog
    } finally {
        Remove-Item Env:SK3_IMPORTER_SUPPRESS_MACRO_OVERLAY -ErrorAction SilentlyContinue
        Remove-Item Env:SK3_IMPORTER_SELECTIVE_LIGHTMAP_REPAIR -ErrorAction SilentlyContinue
    }
    Remove-Item Env:SK3_REFUSED_DETAIL -ErrorAction SilentlyContinue

    $logText = Get-Content -LiteralPath $buildLog -Raw -ErrorAction SilentlyContinue
    if ($logText -match '(?im)^\s*[1-9][0-9]*\s+arenas?\s+left\s+unconverted' -or $logText -match '(?im)\b[1-9][0-9]*\s+refused\b') {
        Fail "The converter reported one or more unconverted/refused arenas. See $buildLog"
    }

    if (-not (Test-Path $stagingData)) { Fail "Converter produced no DLC staging tree at $stagingData" }
    $convertedWorldDir = Join-Path $stagingData "content\world\stream\$worldId"
    if (-not (Test-Path $convertedWorldDir)) { Fail "Converted Xbox 360 world folder was not created: $convertedWorldDir" }

    Write-Host "Validating converted Xbox RenderModelData..." -ForegroundColor Cyan
    $validateLog = Join-Path $logsDir "model-validate.log"
    Run-LoggedChecked $dotnet @($cliDll, "model-validate", $convertedWorldDir, "*.xsf") "Xbox render-model validation" $validateLog

    $badUnlockRows = @()
    $unlockDir = Join-Path $stagingData "unlocks"
    if (Test-Path $unlockDir) {
        foreach ($unlock in Get-ChildItem -LiteralPath $unlockDir -Filter "*.unlock" -File -ErrorAction SilentlyContinue) {
            if (Select-String -LiteralPath $unlock.FullName -Pattern '^WORLDS,' -Quiet -ErrorAction SilentlyContinue) {
                $badUnlockRows += $unlock.FullName
            }
        }
    }
    if ($badUnlockRows.Count -gt 0) {
        Fail "The staging tree still contains unsafe WORLDS unlock rows; refusing to pack it."
    }

    $eaName = "${slug}_x360_ea.big"
    $eaPath = Join-Path $cliBinDir $eaName
    Remove-Item -LiteralPath $eaPath -Force -ErrorAction SilentlyContinue

    Write-Host "Packing Xbox 360 DLC with EA bigfile.exe..." -ForegroundColor Cyan
    $packedEaPath = Run-EABigFilePack $tools.BigFileExe $eaName $cliBinDir
    if (-not [string]::Equals($packedEaPath, $eaPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail "EA BIG packer returned an unexpected output path: $packedEaPath"
    }

    $finalBig = Join-Path $dlcOutputDir $packageName
    Copy-Item -LiteralPath $eaPath -Destination $finalBig -Force
    Remove-Item -LiteralPath $eaPath -Force -ErrorAction SilentlyContinue

    Remove-Item -LiteralPath $x360DistRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $x360DistRoot | Out-Null
    Copy-Item -LiteralPath $convertedWorldDir -Destination (Join-Path $x360DistRoot $worldId) -Recurse -Force

    Remove-Item -LiteralPath $recompTreeRoot -Recurse -Force -ErrorAction SilentlyContinue
    $portableContentDir = Join-Path $recompTreeRoot "$SharedXuid\$TitleId\$MarketplaceType\$contentId"
    $portableHeader = Join-Path $recompTreeRoot "$SharedXuid\$TitleId\Headers\$MarketplaceType\$contentId.header"
    New-Item -ItemType Directory -Force -Path $portableContentDir | Out-Null
    Copy-Item -LiteralPath $finalBig -Destination (Join-Path $portableContentDir $packageName) -Force
    Write-XboxContentHeader $portableHeader $contentId $DisplayName

    if ($KeepStaging) {
        $debugStaging = Join-Path $mapOutput "X360-DLC-Staging"
        Remove-Item -LiteralPath $debugStaging -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $stagingData -Destination $debugStaging -Recurse -Force
    }

    $groupResult = $null
    if (-not [string]::IsNullOrWhiteSpace($GroupName)) {
        $persistentDist = Join-Path $x360DistRoot $worldId
        $groupProject = Update-LocationGroupProject `
            $GroupName $OutputRoot $DisplayName $worldId $persistentDist `
            $SpawnX $SpawnY $SpawnZ $SpawnYaw

        Write-Host "Location Group project now contains $($groupProject.Maps.Count) map(s)." -ForegroundColor Green
        $groupResult = Build-LocationGroupPackage $groupProject $tools $stagingData $sessionRoot ([bool]$KeepStaging)
    }

    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $finalBig).Hash
    $locationGroupInfo = $null
    if (-not [string]::IsNullOrWhiteSpace($GroupName)) { $locationGroupInfo = $GroupName }
    $info = [PSCustomObject]@{
        ImporterVersion = $ImporterVersion
        ConvertedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
        Source = $SourcePath
        SourceDistName = $sourceWorldId
        DistName = $worldId
        DisplayName = $DisplayName
        ContentId = $contentId
        PackageName = $packageName
        Spawn = "$SpawnX,$SpawnY,$SpawnZ,$SpawnYaw"
        BigSha256 = $hash
        ConverterCommit = $ConverterCommit
        DlcBuilderCommit = $ExternalCommit
        MeshMode = "Full rebuild"
        RenderBoundsFix = $true
        XboxUvLayout = "FLOAT2 TEX0 / stride 32"
        XboxMaterialPlatformGuidFix = $true
        SelectiveReferencedLightmapRepair = [bool]($NeutralizeLightmaps -or $BypassBakedLightmaps)
        LightmapRepairMode = $(if ($NeutralizeLightmaps -or $BypassBakedLightmaps) { "Selective material-referenced texture assets; bindings preserved" } else { "Off / lossless" })
        SuppressedMacroOverlay = [bool]$SuppressMacroOverlay
        BypassedBakedLightmapBinding = $false
        SafeAutomaticBlackStubLightmapRepair = $false
        AutomaticBlackTextureRepairDisabled = $true
        LegacyFullCtexNeutralizationSuppressed = $false
        LocationGroup = $locationGroupInfo
    }
    $info | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $mapOutput "conversion-info.json") -Encoding UTF8

    $readme = @"
Skate 3 PS3 -> Xbox 360 converted map

Map: $DisplayName
Source PS3 World ID: $sourceWorldId
Xbox 360 World ID: $worldId
Content ID: $contentId
Spawn: $SpawnX,$SpawnY,$SpawnZ,$SpawnYaw
BIG SHA-256: $hash

OUTPUTS
=======
DLC\$packageName
    EA-packed standalone Skate 3 DLC BIG containing Xbox 360-native map data
    plus generated freeskate/location/menu metadata.

X360-DIST\$worldId\
    Converted Xbox 360 DIST folder (.xsf/.xst/etc.) for inspection/reuse.

Recomp-Content\
    Ready-made ReXGlue/Skate3Recomp Xbox content tree. Copy the contents of
    this folder into Skate3Recomp's user-data root, or use the importer's
    INSTALL-CONVERTED-MAP-TO-RECOMP.bat helper.

Logs\
    Conversion and validation logs.

CONVERSION FIXES USED
=====================
- Full PS3 vertex decode/rebuild (--rebuild-vertices)
- Xbox RenderModelData zero-radius repair
- Rebuilt Xbox TEX0 kept as FLOAT2 at offset 12
- Xbox vertex stride kept at 32 bytes
- PS3 environment.default macro-overlay GUID/stream remapped to the X360 resource
- authored cTex baked-light pages: preserved
- automatic blank/all-black texture replacement: disabled (authored payload preserved)
- selective material-referenced lightmap texture repair: $([bool]($NeutralizeLightmaps -or $BypassBakedLightmaps)) (bindings/alpha/masks/selectors preserved)
- repeating macro-overlay suppression: $([bool]$SuppressMacroOverlay) (diffuse/normal/cTex preserved)
- baked lightmap binding bypass: disabled in v1.16 (unsafe on some maps)
- model-validate must pass before packing
- unsafe WORLDS unlock rows are stripped and then verified absent
- EA bigfile.exe used for final BIG packing

NOTE
====
The BIG contains Xbox 360-native Skate 3 game data. This utility also emits
ReXGlue/Skate3Recomp content registration. It does not create a signed retail
Xbox 360 STFS container for physical-console deployment.
"@
    Set-Content -LiteralPath (Join-Path $mapOutput "README-CONVERTED-MAP.txt") -Value $readme -Encoding UTF8

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host " PS3 -> XBOX 360 MAP CONVERSION COMPLETE"
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Xbox 360 DIST:" -ForegroundColor White
    Write-Host "  $(Join-Path $x360DistRoot $worldId)"
    Write-Host "Xbox 360 DLC BIG:" -ForegroundColor White
    Write-Host "  $finalBig"
    Write-Host "Recomp/X360 content tree:" -ForegroundColor White
    Write-Host "  $recompTreeRoot"
    Write-Host "SHA-256:" -ForegroundColor White
    Write-Host "  $hash"

    $installBig = $finalBig
    $installPackageName = $packageName
    $installContentId = $contentId
    $installDisplayName = $DisplayName
    $installPurgeContentIds = @()

    if ($groupResult) {
        Write-Host ""
        Write-Host "Grouped Locations package:" -ForegroundColor White
        Write-Host "  $($groupResult.FinalBig)"
        Write-Host "  Location tile: $($groupResult.DisplayName)"
        Write-Host "  Sublocations: $($groupResult.MapCount)"
        Write-Host "  Menu parent: $($groupResult.DisplayName) ($($groupResult.MapCount))"
        Write-Host "  Group output: $($groupResult.OutputRoot)"

        # When grouping is enabled, install the GROUP package rather than the
        # current standalone map. The standalone output remains available for
        # testing/inspection but would create a duplicate menu entry.
        $installBig = $groupResult.FinalBig
        $installPackageName = $groupResult.PackageName
        $installContentId = $groupResult.ContentId
        $installDisplayName = $groupResult.DisplayName

        # Remove the legacy v1.07 group ContentID plus every standalone map
        # registration represented by this parent. This is what makes the FE
        # top level actually collapse from many Name (1) entries to one parent.
        $purgeIds = New-Object System.Collections.ArrayList
        if ($groupResult.LegacyContentId) { [void]$purgeIds.Add([string]$groupResult.LegacyContentId) }
        foreach ($gm in @($groupResult.MemberMaps)) {
            $display = [string]$gm.DisplayName
            if ($gm.StandaloneContentId) { [void]$purgeIds.Add([string]$gm.StandaloneContentId) }
            else { [void]$purgeIds.Add((Make-ContentId $display)) }
            if ($gm.StandaloneProductId) { [void]$purgeIds.Add([string]$gm.StandaloneProductId) }
            else { [void]$purgeIds.Add((Make-DlcProductId $display)) }
        }
        $installPurgeContentIds = @($purgeIds | Select-Object -Unique)
    }

    $doInstall = $InstallToRecomp
    if (-not $SkipInstallPrompt -and -not $InstallToRecomp) {
        $promptTarget = if ($groupResult) { "the grouped '$($groupResult.DisplayName)' package" } else { "this finished X360 map" }
        $answer = Read-Host "Install $promptTarget into Skate3Recomp now? [y/N]"
        $doInstall = $answer -match '^(y|yes)$'
    }

    if ($doInstall) {
        if ([string]::IsNullOrWhiteSpace($RecompDir)) {
            $RecompDir = Select-Folder "Select Skate3Recomp folder containing skate3.exe"
            if ([string]::IsNullOrWhiteSpace($RecompDir)) { $RecompDir = Read-Host "Paste Skate3Recomp folder containing skate3.exe" }
        }
        Install-MapToRecomp $RecompDir $installBig $installPackageName $installContentId $installDisplayName $installPurgeContentIds
        if ($groupResult) {
            Write-Host "Launch skate3.exe. The old member Name (1) rows should be gone; Locations should show '$($groupResult.DisplayName) ($($groupResult.MapCount))'. Select it once to open the child map list." -ForegroundColor Green
        } else {
            Write-Host "Launch skate3.exe and look for '$DisplayName' under Locations." -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
} finally {
    if (Test-Path $sessionRoot) { Remove-Item -LiteralPath $sessionRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
