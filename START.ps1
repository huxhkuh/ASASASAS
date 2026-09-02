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

function Ensure-VCRedistBuildComponent {
    $vsInstallerRoot = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
    $vsWhere = Join-Path $vsInstallerRoot "vswhere.exe"
    $componentId = "Microsoft.VisualStudio.Component.VC.Redist.14.Latest"

    if (Test-Path -LiteralPath $vsWhere) {
        $qualifiedInstall = (& $vsWhere -latest -products * -requires $componentId -property installationPath 2>$null | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($qualifiedInstall)) {
            return
        }
    }

    Write-Host "Installing the Visual C++ component required to package OpenClaw..." -ForegroundColor Cyan

    $existingInstall = $null
    if (Test-Path -LiteralPath $vsWhere) {
        $existingInstall = (& $vsWhere -latest -products * -property installationPath 2>$null | Select-Object -First 1)
    }

    $vsSetup = Join-Path $vsInstallerRoot "setup.exe"
    if (-not [string]::IsNullOrWhiteSpace($existingInstall) -and (Test-Path -LiteralPath $vsSetup)) {
        $setupArguments = "modify --installPath `"$existingInstall`" --add $componentId --passive --wait --norestart"
        $setupProcess = Start-Process -FilePath $vsSetup -ArgumentList $setupArguments -Verb RunAs -Wait -PassThru
        if ($setupProcess.ExitCode -notin @(0, 3010)) {
            throw "Visual Studio Installer could not add $componentId (exit code $($setupProcess.ExitCode))."
        }
    } else {
        if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
            throw "Visual Studio Build Tools is required. Install its C++ Redistributable component, then run this script again."
        }

        & winget.exe install `
            --id Microsoft.VisualStudio.2022.BuildTools `
            --source winget `
            -e `
            --accept-source-agreements `
            --accept-package-agreements `
            --interactive `
            --override "--wait --passive --norestart --add $componentId"
        if ($LASTEXITCODE -ne 0) {
            throw "winget could not install Visual Studio Build Tools with $componentId (exit code $LASTEXITCODE)."
        }
    }

    if (-not (Test-Path -LiteralPath $vsWhere)) {
        throw "Visual Studio Build Tools finished, but vswhere.exe was not found. Restart Windows and rerun this script."
    }

    $qualifiedInstall = (& $vsWhere -latest -products * -requires $componentId -property installationPath 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($qualifiedInstall)) {
        throw "Visual Studio Build Tools finished without the required $componentId component."
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
    $upgradeContent = $upgradeContent.Replace(
        '& dotnet.exe test $Project --no-restore',
        '& dotnet.exe test $Project')
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

    # The localization pass moved user-visible copy out of C# and into .resw.
    # Keep source-contract tests pointed at the resource lookups rather than
    # the former hard-coded English text. These replacements are idempotent so
    # an interrupted upgrade can be resumed safely.
    $contractTestFixes = @{
        "tests\OpenClaw.Tray.Tests\ChannelsPageWebLoginRecoveryContractTests.cs" = @(
            'Assert.Contains("isn''t available on this gateway yet", source, StringComparison.Ordinal);',
            'Assert.Contains("ChannelsPage_LinkingUnavailableFormat", source, StringComparison.Ordinal);'
        )
        "tests\OpenClaw.Tray.Tests\SessionActionsWiringTests.cs" = @(
            'Assert.Contains("\"The gateway didn''t accept the request. Try again.\"", source);',
            'Assert.Contains("LocalizationHelper.GetString(\"SessionsPage_ActionRejectedMessage\")", source);'
        )
        "tests\OpenClaw.Tray.Tests\DiagnosticsPageContractTests.cs" = @(
            'Assert.Contains("CopyDiagnosticText(\"Support context\"", cs);',
            'Assert.Contains("LocalizationHelper.GetString(\"DebugPage_SupportContext\")", cs);',
            'Assert.Contains("CopyDiagnosticText(\r\n            \"Summary debug bundle\"", cs);',
            'Assert.Contains("LocalizationHelper.GetString(\"DebugPage_SummaryDebugBundle\")", cs);',
            'Assert.Contains("CopyDiagnosticText(\"Browser setup guidance\"", cs);',
            'Assert.Contains("LocalizationHelper.GetString(\"DebugPage_BrowserSetupGuidance\")", cs);',
            'Assert.Contains("CopyDiagnosticText(\"Port diagnostics\"", cs);',
            'Assert.Contains("LocalizationHelper.GetString(\"DebugPage_PortDiagnostics\")", cs);',
            'Assert.Contains("CopyDiagnosticText(\"Capability diagnostics\"", cs);',
            'Assert.Contains("LocalizationHelper.GetString(\"DebugPage_CapabilityDiagnostics\")", cs);'
        )
        "tests\OpenClaw.Tray.Tests\AppRefactorContractTests.cs" = @(
            'Assert.Contains("Check SSH tunnel settings and logs.", method);',
            'Assert.Contains("LocalizationHelper.GetString(\"Toast_SshTunnelCheckSettings\")", method);',
            'Assert.Contains("Retry with validated fallback {args.GatewayFallbackVersion}", complete);',
            'Assert.Contains("SetupLocalization.Format(\"Setup_Complete_RetryFallbackFormat\", args.GatewayFallbackVersion)", complete);',
            'Assert.Contains("Couldn''t read Windows permission status", build);',
            'Assert.Contains("SetupLocalization.GetString(\"Setup_Capabilities_PermissionStatusErrorTitle\")", build);',
            'Assert.Contains("Review permissions later in Settings", build);',
            'Assert.Contains("SetupLocalization.Format(\"Setup_Capabilities_PermissionStatusErrorFormat\", ex.Message)", build);',
            'Assert.Contains("Retry Windows integration", finalizationError);',
            'Assert.Contains("SetupLocalization.GetString(\"Setup_Wizard_RetryWindows\")", finalizationError);',
            'Assert.Contains("<ListView x:Name=\"GatewayChoiceSelector\"", xaml);',
            'Assert.Contains("x:Name=\"GatewayChoiceSelector\"", xaml);',
            'Assert.Contains("Node Sandbox unavailable", reject);',
            'Assert.Contains("L(\"SandboxPage_EnableUnavailableDialogTitle\")", reject);',
            'Assert.Contains("usable MXC backend", reject);',
            'Assert.Contains("Lf(\"SandboxPage_EnableUnavailableDialogMessageFormat\", reasonText)", reject);'
        )
    }

    foreach ($entry in $contractTestFixes.GetEnumerator()) {
        $testPath = Join-Path $workDirectory $entry.Key
        $testContent = [System.IO.File]::ReadAllText($testPath)
        $replacementValues = @($entry.Value)
        if (($replacementValues.Count % 2) -ne 0) {
            throw "Invalid contract-test replacement list for $($entry.Key)."
        }
        for ($index = 0; $index -lt $replacementValues.Count; $index += 2) {
            $testContent = $testContent.Replace(
                [string]$replacementValues[$index],
                [string]$replacementValues[$index + 1])
        }
        [System.IO.File]::WriteAllText($testPath, $testContent)
    }

    $localizationTestsPath = Join-Path $workDirectory "tests\OpenClaw.Tray.Tests\LocalizationValidationTests.cs"
    $localizationTests = [System.IO.File]::ReadAllText($localizationTestsPath)
    if (-not $localizationTests.Contains('key.StartsWith("Activation_", StringComparison.Ordinal)')) {
        $setupDeferredLine = '        || key.StartsWith("Setup_", StringComparison.Ordinal)'
        $legacyDeferredBlock = @'
        // These runtime surfaces were moved from hard-coded English into .resw
        // as part of the Hebrew localization pass. Hebrew supplies complete
        // translations; the four legacy locale files deliberately retain the
        // synchronized en-us fallback until their maintainers translate them.
        || key.StartsWith("Activation_", StringComparison.Ordinal)
        || key.StartsWith("Checkpoints_", StringComparison.Ordinal)
        || key.StartsWith("ConfigPage_", StringComparison.Ordinal)
        || key.StartsWith("DebugPage_", StringComparison.Ordinal)
        || key.StartsWith("DiagnosticsBundleDialog_", StringComparison.Ordinal)
        || key.StartsWith("SandboxPage_", StringComparison.Ordinal)
        || key.StartsWith("SchemaConfigEditor_", StringComparison.Ordinal)
        || key.StartsWith("SessionsPage_", StringComparison.Ordinal)
        || key.StartsWith("SkillsPage_", StringComparison.Ordinal)
        || key.StartsWith("Toast_", StringComparison.Ordinal)
        || key.StartsWith("TrayMenu_", StringComparison.Ordinal)
        || key.StartsWith("UsagePage_", StringComparison.Ordinal)
        || key.StartsWith("VoiceSettingsPage_Inline", StringComparison.Ordinal)
        || key.StartsWith("Common_", StringComparison.Ordinal)
        || key.StartsWith("SettingsPage_TestNotification", StringComparison.Ordinal)
        || key.StartsWith("SettingsPage_RemoveGatewayDialog", StringComparison.Ordinal)
        || key.Equals("SettingsPage_AppDisplayName.Text", StringComparison.Ordinal)
'@
        if (-not $localizationTests.Contains($setupDeferredLine)) {
            throw "Could not update the legacy-locale fallback policy test."
        }
        $localizationTests = $localizationTests.Replace(
            $setupDeferredLine,
            $setupDeferredLine + [Environment]::NewLine + $legacyDeferredBlock.TrimEnd())
        [System.IO.File]::WriteAllText($localizationTestsPath, $localizationTests)
    }

    Ensure-VCRedistBuildComponent

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
