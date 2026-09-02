[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$upstreamRepository = "https://github.com/openclaw/openclaw-windows-node.git"
$baseCommit = "f46400aab24e835d9f7339b3e94821260a42d3c0"
$workDirectory = Join-Path $PSScriptRoot "openclaw-hebrew-source"
$patchFile = Join-Path $env:TEMP ("openclaw-hebrew-" + [Guid]::NewGuid().ToString("N") + ".patch")

function Refresh-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = @($machinePath, $userPath) -join ";"
}

function Ensure-Git {
    Refresh-ProcessPath
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        return
    }

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "Git is required. Install Git for Windows, then run this script again."
    }

    Write-Host "Installing Git for Windows..." -ForegroundColor Cyan
    & winget.exe install --id Git.Git --source winget -e --accept-source-agreements --accept-package-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "Git installation failed with exit code $LASTEXITCODE."
    }

    Refresh-ProcessPath
    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        throw "Git was installed but is not available yet. Restart Windows and run this script again."
    }
}

try {
    Write-Host "Preparing OpenClaw Hebrew..." -ForegroundColor Magenta
    Ensure-Git

    $sourceIsPrepared = $false
    if (Test-Path -LiteralPath $workDirectory) {
        $currentSubject = & git.exe -C $workDirectory log -1 --format=%s 2>$null
        $sourceIsPrepared = $LASTEXITCODE -eq 0 -and $currentSubject -eq "Add complete Hebrew localization and RTL support"
        if (-not $sourceIsPrepared) {
            throw "The folder exists but does not contain the prepared Hebrew source: $workDirectory"
        }

        Write-Host "Reusing the Hebrew source that was already prepared." -ForegroundColor Green
    }

    if (-not $sourceIsPrepared) {
        $patchParts = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "github-part-*.txt" -File | Sort-Object Name)
        if ($patchParts.Count -eq 0) {
            throw "Hebrew localization patch files are missing."
        }

        $writer = [System.IO.File]::CreateText($patchFile)
        try {
            foreach ($part in $patchParts) {
                $writer.Write([System.IO.File]::ReadAllText($part.FullName))
            }
        } finally {
            $writer.Dispose()
        }

        Write-Host "Downloading the pinned OpenClaw source..." -ForegroundColor Cyan
        & git.exe clone $upstreamRepository $workDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "Could not clone the OpenClaw repository."
        }

        & git.exe -C $workDirectory checkout $baseCommit
        if ($LASTEXITCODE -ne 0) {
            throw "Could not check out the required OpenClaw version."
        }

        Write-Host "Applying the complete Hebrew localization..." -ForegroundColor Cyan
        & git.exe -C $workDirectory am $patchFile
        if ($LASTEXITCODE -ne 0) {
            throw "The Hebrew localization patch could not be applied."
        }
    }

    $upgradeScript = Join-Path $workDirectory "UPGRADE-TO-HEBREW.ps1"
    $upgradeContent = [System.IO.File]::ReadAllText($upgradeScript)
    $oldWingetCommand = '& winget.exe install --id $PackageId -e'
    $fixedWingetCommand = '& winget.exe install --id $PackageId --source winget -e'
    $interactiveWingetCommand = '& winget.exe install --id $PackageId --source winget -e --interactive'
    if ($upgradeContent.Contains($interactiveWingetCommand)) {
        # Already configured by an earlier resume attempt.
    } elseif ($upgradeContent.Contains($oldWingetCommand)) {
        $upgradeContent = $upgradeContent.Replace($oldWingetCommand, $interactiveWingetCommand)
    } elseif ($upgradeContent.Contains($fixedWingetCommand)) {
        $upgradeContent = $upgradeContent.Replace($fixedWingetCommand, $interactiveWingetCommand)
    } else {
        throw "Could not configure the upgrade script to use the winget community source."
    }
    $upgradeContent = $upgradeContent.Replace(' --disable-interactivity', '')
    [System.IO.File]::WriteAllText($upgradeScript, $upgradeContent)

    foreach ($relativeSourcePath in @(
        "src\OpenClaw.Tray.WinUI\App.xaml.cs",
        "src\OpenClaw.SetupEngine.UI\SetupLocalization.cs"
    )) {
        $sourcePath = Join-Path $workDirectory $relativeSourcePath
        $sourceContent = [System.IO.File]::ReadAllText($sourcePath)
        $sourceContent = [System.Text.RegularExpressions.Regex]::Replace(
            $sourceContent,
            '(?<!global::)Windows\.Globalization\.',
            'global::Windows.Globalization.')
        [System.IO.File]::WriteAllText($sourcePath, $sourceContent)
    }

    $sessionsPagePath = Join-Path $workDirectory "src\OpenClaw.Tray.WinUI\Pages\SessionsPage.xaml.cs"
    $sessionsPageContent = [System.IO.File]::ReadAllText($sessionsPagePath)
    $sessionsPageContent = $sessionsPageContent.Replace(
        'LocalizationHelper.GetString("SessionsPage_Refresh")',
        'LocalizationHelper.GetString("SessionsPage_RefreshAction")')
    [System.IO.File]::WriteAllText($sessionsPagePath, $sessionsPageContent)

    $stringsDirectory = Join-Path $workDirectory "src\OpenClaw.Tray.WinUI\Strings"
    foreach ($resourceFile in Get-ChildItem -LiteralPath $stringsDirectory -Filter "Resources.resw" -File -Recurse) {
        $resourceContent = [System.IO.File]::ReadAllText($resourceFile.FullName)
        $resourceContent = $resourceContent.Replace(
            '<data name="SessionsPage_Refresh"',
            '<data name="SessionsPage_RefreshAction"')
        [System.IO.File]::WriteAllText($resourceFile.FullName, $resourceContent)
    }

    $buildScript = Join-Path $workDirectory "build.ps1"
    $buildContent = [System.IO.File]::ReadAllText($buildScript)
    $buildContent = $buildContent.Replace(
        '$successCount = ($buildResults.Values | Where-Object { $_ -eq $true }).Count',
        '$successCount = @($buildResults.Values | Where-Object { $_ -eq $true }).Count')
    $buildContent = $buildContent.Replace(
        '$failCount = ($buildResults.Values | Where-Object { $_ -eq $false }).Count',
        '$failCount = @($buildResults.Values | Where-Object { $_ -eq $false }).Count')
    [System.IO.File]::WriteAllText($buildScript, $buildContent)

    Write-Host "Starting the tested in-place upgrade..." -ForegroundColor Cyan
    & $upgradeScript
    if ($LASTEXITCODE -ne 0) {
        throw "The upgrade script stopped with exit code $LASTEXITCODE."
    }
} catch {
    Write-Host "`nProcess stopped: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Copy the complete PowerShell output and send it back for diagnosis." -ForegroundColor Yellow
    exit 1
} finally {
    Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
}
