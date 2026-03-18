#Requires -Version 5.1
<#
.SYNOPSIS
    ClawShell one-click installer

.DESCRIPTION
    Download and install ClawShell (OpenClaw + GUI automation gateway).

    Installs:
      - ClawShell daemon + UI + plugins (Windows side)
      - ClawShell WSL2 VM (contains OpenClaw + MCP Server)

    Install latest version:
      irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex

    Install specific version (recommended for pinning):
      irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex -Version 0.1.0
      # Or download install.ps1 from the specific release (URL already pinned):
      irm https://github.com/carlos-Ng/ClawShell/releases/download/v0.1.0/install.ps1 | iex

    Release assets:
      clawshell-windows-<ver>.zip  -- All Windows binaries (daemon, vmm, ui, dll)
      clawshell-rootfs.tar.gz      -- WSL2 VM image (downloaded on first install)
      install.ps1                  -- This installer script (included in each release)

.PARAMETER Version
    Version number to install (e.g. 0.1.0). Leave empty for latest.

.PARAMETER Uninstall
    Uninstall ClawShell

.PARAMETER Upgrade
    Upgrade ClawShell components (preserves user data)
#>

[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Upgrade,
    [string]$Version = "",
    [string]$InstallDir = "",
    [string]$ApiKey = "",
    [string]$ApiProvider = "",
    [string]$ReleaseUrl = "",
    [string]$LocalModelUrl = "",
    [string]$LocalModelId = ""
)

# -- Config ----------------------------------------------------------------

$ErrorActionPreference = "Stop"

if ($Host.Name -eq 'ConsoleHost') {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
    } catch {}
}

$AppName        = "ClawShell"
$DistroName     = "ClawShell"
$DefaultInstDir = Join-Path $env:LOCALAPPDATA $AppName
$StartupDir     = [Environment]::GetFolderPath("Startup")
$UninstallRegKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"

# GitHub Release URL construction
if (-not $ReleaseUrl) {
    if ($Version) {
        $DefaultReleaseBase = "https://github.com/carlos-Ng/ClawShell/releases/download/v$Version"
    } else {
        $DefaultReleaseBase = "https://github.com/carlos-Ng/ClawShell/releases/latest/download"
    }
}

# Release assets (zip contains all Windows binaries; rootfs packaged separately so upgrades can skip it)
$RootfsName = "clawshell-rootfs.tar.gz"

# Files expected inside the zip (used for install verification)
$WindowsBinFiles = @(
    "claw_shell_service.exe"
    "claw_shell_vmm.exe"
    "claw_shell_ui.exe"
    "capability_ax.dll"
    "security_filter.dll"
)

# -- Helper functions ------------------------------------------------------

function Write-Banner {
    param([string]$Text)
    $line = "=" * 50
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "  > $Text" -ForegroundColor White
}

function Write-Ok {
    param([string]$Text)
    Write-Host "  [OK] $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  [WARN] $Text" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    Write-Host "  [ERR] $Text" -ForegroundColor Red
}

function Confirm-Continue {
    param([string]$Prompt = "Continue?")
    $answer = Read-Host "$Prompt (Y/n)"
    if ($answer -and $answer -notmatch '^[Yy]') {
        Write-Host "Cancelled."
        exit 0
    }
}

# Run wsl.exe with stdout/stderr/console completely detached from the parent console.
# This prevents WSL boot messages, systemd journal output, dbus noise, etc. from
# leaking into the installer's formatted output and breaking the layout.
function Invoke-WslSilent {
    param(
        [string]$WslArguments,
        [string]$InputText = $null
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = $WslArguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($InputText -ne $null -and $InputText -ne '') {
        $psi.RedirectStandardInput = $true
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($InputText -ne $null -and $InputText -ne '') {
        $proc.StandardInput.Write($InputText)
        $proc.StandardInput.Close()
    }
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return $proc.ExitCode
}

# Run a WSL command in the background with a visual spinner.
# Optionally monitors a directory for VHDX disk growth (useful for wsl --import).
function Invoke-WslWithSpinner {
    param(
        [string]$WslArguments,
        [string]$StatusPrefix = "Working",
        [string]$MonitorDir = $null
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "wsl.exe"
    $psi.Arguments = $WslArguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)

    $spinChars = @('-', '\', '|', '/')
    $i = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $proc.HasExited) {
        $spin = $spinChars[$i % 4]
        $elapsed = [math]::Floor($sw.Elapsed.TotalSeconds)
        $extra = ""
        if ($MonitorDir -and (Test-Path $MonitorDir)) {
            $vhdx = Get-ChildItem $MonitorDir -Filter "*.vhdx" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($vhdx) {
                $diskMB = [math]::Round($vhdx.Length / 1MB, 0)
                $extra = ", ${diskMB} MB written"
            }
        }
        Write-Host "`r  $spin $StatusPrefix (${elapsed}s$extra)              " -NoNewline
        Start-Sleep -Milliseconds 300
        $i++
    }
    $sw.Stop()
    Write-Host "`r                                                                              `r" -NoNewline

    $proc.StandardOutput.ReadToEnd() | Out-Null
    $proc.StandardError.ReadToEnd() | Out-Null

    return $proc.ExitCode
}

# -- Uninstall -------------------------------------------------------------

if ($Uninstall) {
    Write-Banner "Uninstall $AppName"

    Write-Step "Stopping $AppName processes ..."
    Get-Process -Name "claw_shell_service", "claw_shell_vmm", "claw_shell_ui" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Write-Step "Shutting down WSL distro ..."
    wsl -t $DistroName 2>$null

    $removeVM = Read-Host "  Delete $DistroName VM and all its data? (y/N)"
    if ($removeVM -match '^[Yy]') {
        Write-Step "Unregistering WSL distro ..."
        wsl --unregister $DistroName 2>$null
        Write-Ok "VM deleted"
    } else {
        Write-Warn "VM kept (you can manually run: wsl --unregister $DistroName)"
    }

    $startupLink = Join-Path $StartupDir "$AppName.lnk"
    if (Test-Path $startupLink) {
        Remove-Item $startupLink -Force
        Write-Ok "Startup shortcut removed"
    }

    $instDir = $DefaultInstDir
    if (Test-Path $UninstallRegKey) {
        $regInstDir = (Get-ItemProperty $UninstallRegKey -ErrorAction SilentlyContinue).InstallLocation
        if ($regInstDir) { $instDir = $regInstDir }
    }

    if (Test-Path $instDir) {
        Write-Step "Removing install directory $instDir ..."
        Remove-Item $instDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "Install files removed"
    }

    if (Test-Path $UninstallRegKey) {
        Remove-Item $UninstallRegKey -Force
        Write-Ok "Registry entries cleaned"
    }

    Write-Host ""
    Write-Ok "$AppName has been uninstalled"
    exit 0
}

# -- Environment checks ----------------------------------------------------

Write-Banner "$AppName Installer v$((Get-Date).ToString('yyyy.M.d'))"

Write-Step "Checking system requirements ..."

# Windows version
$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Build -lt 19041) {
    Write-Err "Requires Windows 10 2004 (Build 19041) or later"
    Write-Err "Current version: $($osVersion.ToString())"
    exit 1
}
Write-Ok "Windows version: $($osVersion.ToString())"

# curl.exe (built into Windows 10 17063+)
$CurlExe = $null
$_curlCmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
if ($_curlCmd) { $CurlExe = $_curlCmd.Source }
if (-not $CurlExe) {
    Write-Err "curl.exe not found"
    Write-Host ""
    Write-Host "  curl.exe is built into Windows 10 (Build 17063) and later." -ForegroundColor Yellow
    Write-Host "  If your system doesn't have it, download from:" -ForegroundColor Yellow
    Write-Host "    https://curl.se/windows/" -ForegroundColor White
    Write-Host "  Then re-run this script." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Ok "curl.exe: $CurlExe"

# WSL2
$wslStatus = $null
try {
    $wslStatus = wsl --status 2>&1
} catch {}

$wslInstalled = $false
if ($LASTEXITCODE -eq 0 -or ($wslStatus -match "Default Version")) {
    $wslInstalled = $true
}

if (-not $wslInstalled) {
    Write-Warn "WSL2 is not installed or not enabled"
    Write-Host ""
    Write-Host "  WSL2 must be installed first. Run in an admin PowerShell:" -ForegroundColor Yellow
    Write-Host "    wsl --install --no-distribution" -ForegroundColor White
    Write-Host "  Reboot after installation, then re-run this script." -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Ok "WSL2 ready"

# Check if already installed
$existingDistro = wsl -l -q 2>$null | Where-Object { $_ -match "^$DistroName$" }
$isUpgrade = $false

if ($existingDistro -and -not $Upgrade) {
    Write-Warn "$DistroName VM already exists"
    Write-Host ""
    Write-Host "  Options:" -ForegroundColor Yellow
    Write-Host "    1) Upgrade (keep data, update components)" -ForegroundColor White
    Write-Host "    2) Clean install (delete existing data)" -ForegroundColor White
    Write-Host "    3) Cancel" -ForegroundColor White
    $choice = Read-Host "  Choose (1/2/3)"
    switch ($choice) {
        "1" { $isUpgrade = $true }
        "2" {
            Write-Step "Unregistering existing distro ..."
            wsl -t $DistroName 2>$null
            wsl --unregister $DistroName 2>$null
            Write-Ok "Cleared"
        }
        default { Write-Host "Cancelled."; exit 0 }
    }
}

if ($Upgrade) { $isUpgrade = $true }

# -- Install path ----------------------------------------------------------

if (-not $InstallDir) {
    if (Test-Path $UninstallRegKey) {
        $regInstDir = (Get-ItemProperty $UninstallRegKey -ErrorAction SilentlyContinue).InstallLocation
        if ($regInstDir) { $InstallDir = $regInstDir }
    }
}

if (-not $InstallDir) {
    $InstallDir = $DefaultInstDir
}

$DistroDir = Join-Path $InstallDir "vm"
$BinDir    = Join-Path $InstallDir "bin"
$ConfigDir = Join-Path $InstallDir "config"
$DownloadDir = Join-Path $InstallDir "downloads"

Write-Ok "Install path: $InstallDir"

# -- Download --------------------------------------------------------------

if (-not $isUpgrade) {
    Write-Banner "Download Components"
} else {
    Write-Banner "Download Updates"
}

if (-not $ReleaseUrl) { $ReleaseUrl = $DefaultReleaseBase }

New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null

function Get-RemoteFileSize {
    param([string]$Url)
    $output = & $CurlExe -s --fail -I -L --connect-timeout 10 $Url 2>&1
    $expectedSize = [long]-1
    foreach ($line in $output) {
        if ($line -match "(?i)^content-length:\s*(\d+)") {
            $expectedSize = [long]$Matches[1]
        }
    }
    return $expectedSize
}

function Invoke-Download {
    param([string]$Url, [string]$Dest, [string]$Desc)

    $expectedSize = Get-RemoteFileSize -Url $Url
    if ($expectedSize -gt 0) {
        $sizeMB = [math]::Round($expectedSize / 1MB, 1)
        Write-Step "Downloading $Desc ($sizeMB MB) ..."
    } else {
        Write-Step "Downloading $Desc ..."
    }
    Write-Host ""
    & $CurlExe -L --fail "-#" --connect-timeout 15 --retry 3 --retry-delay 2 -o $Dest $Url
    Write-Host ""
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Download failed: $Desc (curl exit code: $LASTEXITCODE)"
        Write-Err "  URL: $Url"
        if ($LASTEXITCODE -eq 22) {
            Write-Err "  Server returned an error (file may not exist or URL is invalid)"
        } elseif ($LASTEXITCODE -eq 28) {
            Write-Err "  Connection timed out, please check your network"
        }
        Write-Host ""
        Write-Host "  If you cannot access GitHub, download these files manually:" -ForegroundColor Yellow
        Write-Host "    - clawshell-windows-<version>.zip" -ForegroundColor White
        Write-Host "    - clawshell-rootfs.tar.gz (first install)" -ForegroundColor White
        Write-Host "  Place them in $DownloadDir and re-run the script." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }

    # File size validation
    if ($expectedSize -gt 0) {
        $actualSize = (Get-Item $Dest).Length
        if ($actualSize -ne $expectedSize) {
            Write-Err "File integrity check failed: $Desc"
            Write-Err "  Expected: $expectedSize bytes, Actual: $actualSize bytes"
            Write-Host ""
            Write-Host "  Download incomplete. Remove the partial file and re-run:" -ForegroundColor Yellow
            Write-Host "    Remove-Item '$Dest'" -ForegroundColor White
            Write-Host ""
            exit 1
        }
    }

    # File format validation (detect proxy/firewall HTML error pages)
    if ((Test-Path $Dest) -and (Get-Item $Dest).Length -ge 4) {
        $headBytes = New-Object byte[] 4
        $fs = [System.IO.File]::OpenRead($Dest)
        try { $fs.Read($headBytes, 0, 4) | Out-Null } finally { $fs.Close() }
        $isZip  = ($headBytes[0] -eq 0x50 -and $headBytes[1] -eq 0x4B)
        $isGzip = ($headBytes[0] -eq 0x1F -and $headBytes[1] -eq 0x8B)
        if (-not ($isZip -or $isGzip)) {
            Write-Err "Downloaded file has unexpected format (possibly a proxy/firewall error page)"
            Write-Err "  Please verify your network connection and that GitHub is accessible"
            Remove-Item $Dest -Force -ErrorAction SilentlyContinue
            exit 1
        }
    }

    Write-Ok $Desc
}

# Network connectivity pre-check (fail early instead of showing a fake progress bar)
if ($ReleaseUrl -match 'github\.com') {
    Write-Step "Checking GitHub connectivity ..."
    $null = & $CurlExe -s --fail --head -L --connect-timeout 10 "https://github.com" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Cannot connect to GitHub, please check your network"
        Write-Host ""
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "    - No network connection" -ForegroundColor White
        Write-Host "    - Firewall/proxy blocking GitHub" -ForegroundColor White
        Write-Host "    - GitHub is temporarily unavailable" -ForegroundColor White
        Write-Host ""
        Write-Host "  For offline install, download the packages manually and use -ReleaseUrl to specify a local path." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
    Write-Ok "Network connection OK"
}

# Resolve actual version number (for constructing the versioned zip filename)
$ResolvedVersion = $Version
if (-not $ResolvedVersion) {
    Write-Step "Querying latest version ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $apiResp = Invoke-RestMethod -Uri "https://api.github.com/repos/carlos-Ng/ClawShell/releases/latest" -ErrorAction Stop
        $ResolvedVersion = $apiResp.tag_name -replace '^v', ''
        Write-Ok "Latest version: $ResolvedVersion"
    } catch {
        Write-Warn "Cannot query GitHub API, will attempt direct download"
        $ResolvedVersion = "latest"
    }
}

# Zip filename includes version (matches CMake release target output)
$WindowsZipName = if ($ResolvedVersion -eq "latest") {
    "clawshell-windows.zip"
} else {
    "clawshell-windows-$ResolvedVersion.zip"
}

# Download Windows binary zip (needed for both upgrade and fresh install)
$zipDest = Join-Path $DownloadDir $WindowsZipName
Invoke-Download -Url "$ReleaseUrl/$WindowsZipName" -Dest $zipDest -Desc "Windows package ($WindowsZipName)"

# Download rootfs on first install (skip on upgrade)
if (-not $isUpgrade) {
    $rootfsDest = Join-Path $DownloadDir $RootfsName
    Invoke-Download -Url "$ReleaseUrl/$RootfsName" -Dest $rootfsDest -Desc "VM image ($RootfsName)"
}

# -- Configuration wizard --------------------------------------------------

if (-not $isUpgrade) {
    Write-Banner "Configuration"

    # API Provider
    if (-not $ApiProvider) {
        Write-Host "  Select AI model provider:" -ForegroundColor White
        Write-Host "    1) Anthropic (Claude)  -- Recommended" -ForegroundColor White
        Write-Host "    2) OpenAI (GPT)" -ForegroundColor White
        Write-Host "    3) Local model (llama.cpp / Ollama / OpenAI-compatible)" -ForegroundColor White
        Write-Host "    4) Other (configure later in OpenClaw WebUI)" -ForegroundColor White
        $providerChoice = Read-Host "  Choose (1/2/3/4)"
        switch ($providerChoice) {
            "1" { $ApiProvider = "anthropic" }
            "2" { $ApiProvider = "openai" }
            "3" { $ApiProvider = "local" }
            default { $ApiProvider = "skip" }
        }
    }

    # Local Model configuration
    if ($ApiProvider -eq "local") {
        Write-Host ""
        Write-Host "  +---------------------------------------------+" -ForegroundColor Cyan
        Write-Host "  |  Local Model Configuration                  |" -ForegroundColor Cyan
        Write-Host "  |                                             |" -ForegroundColor Cyan
        Write-Host "  |  Supports any OpenAI-compatible API:        |" -ForegroundColor Cyan
        Write-Host "  |    - llama.cpp (--host 0.0.0.0 -p 8080)    |" -ForegroundColor Cyan
        Write-Host "  |    - Ollama (http://host:11434)             |" -ForegroundColor Cyan
        Write-Host "  |    - vLLM / SGLang / LocalAI / LM Studio   |" -ForegroundColor Cyan
        Write-Host "  +---------------------------------------------+" -ForegroundColor Cyan
        Write-Host ""

        if (-not $LocalModelUrl) {
            Write-Host "  Enter model service URL" -ForegroundColor White
            Write-Host "  Example: http://192.168.1.100:8080  (llama.cpp)" -ForegroundColor DarkGray
            Write-Host "  Example: http://192.168.1.100:11434 (Ollama)" -ForegroundColor DarkGray
            $LocalModelUrl = Read-Host "  Model URL"
        }

        if (-not $LocalModelUrl) {
            Write-Warn "No model URL provided, you can configure it later in OpenClaw WebUI"
            $ApiProvider = "skip"
        } else {
            $isOllama = $LocalModelUrl -match ":11434"

            if (-not $LocalModelId) {
                Write-Host ""
                Write-Host "  Enter model ID (leave empty for default)" -ForegroundColor White
                if ($isOllama) {
                    Write-Host "  Example: qwen3.5:27b, glm-4.7-flash, deepseek-r1:32b" -ForegroundColor DarkGray
                    $defaultModelId = "glm-4.7-flash"
                } else {
                    Write-Host "  Example: qwen3.5, glm-4.7, llama-3.3-70b" -ForegroundColor DarkGray
                    $defaultModelId = "default"
                }
                $LocalModelId = Read-Host "  Model ID (default: $defaultModelId)"
                if (-not $LocalModelId) { $LocalModelId = $defaultModelId }
            }

            Write-Ok "Local model configured ($LocalModelUrl -> $LocalModelId)"
        }
    }

    # API Key (cloud providers)
    if ($ApiProvider -in @("anthropic", "openai") -and -not $ApiKey) {
        Write-Host ""
        if ($ApiProvider -eq "anthropic") {
            Write-Host "  Enter your Anthropic API Key" -ForegroundColor White
            Write-Host "  (Get it from https://console.anthropic.com/account/keys)" -ForegroundColor DarkGray
        } else {
            Write-Host "  Enter your OpenAI API Key" -ForegroundColor White
            Write-Host "  (Get it from https://platform.openai.com/api-keys)" -ForegroundColor DarkGray
        }
        $ApiKey = Read-Host "  API Key"

        if (-not $ApiKey) {
            Write-Warn "No API Key provided, you can configure it later in OpenClaw WebUI"
            $ApiProvider = "skip"
        }
    }

    if ($ApiProvider -ne "skip") {
        Write-Ok "API configuration ready ($ApiProvider)"
    }
}

# -- Install files ---------------------------------------------------------

Write-Banner "Install"

# Create directories
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
New-Item -ItemType Directory -Path $DistroDir -Force | Out-Null

# Stop running processes
Write-Step "Stopping old processes ..."
Get-Process -Name "claw_shell_service", "claw_shell_vmm", "claw_shell_ui" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# Extract Windows package
Write-Step "Extracting Windows package ..."
$zipPath = Join-Path $DownloadDir $WindowsZipName
Expand-Archive -Path $zipPath -DestinationPath $BinDir -Force
Write-Ok "Program files installed"

# -- Import WSL Distro -----------------------------------------------------

if (-not $isUpgrade) {
    Write-Step "Importing WSL VM ..."
    $rootfsPath = Join-Path $DownloadDir $RootfsName

    if (-not (Test-Path $rootfsPath)) {
        Write-Err "rootfs file not found: $rootfsPath"
        exit 1
    }

    $rootfsSizeMB = [math]::Round((Get-Item $rootfsPath).Length / 1MB, 0)
    $exitCode = Invoke-WslWithSpinner `
        -WslArguments "--import $DistroName `"$DistroDir`" `"$rootfsPath`"" `
        -StatusPrefix "Importing VM image (${rootfsSizeMB} MB compressed)" `
        -MonitorDir $DistroDir
    if ($exitCode -ne 0) {
        Write-Err "WSL import failed (exit code: $exitCode)"
        exit 1
    }
    Write-Ok "VM imported"

    # Warm up the distro (first boot emits systemd/dbus messages; run silently to absorb them)
    Write-Step "Initializing WSL VM (first boot) ..."
    Invoke-WslWithSpinner `
        -WslArguments "-d $DistroName -- bash -c `"sleep 2 && exit 0`"" `
        -StatusPrefix "First boot initialization" | Out-Null
    Write-Ok "WSL VM ready"
}

# -- Write config ----------------------------------------------------------

Write-Step "Writing configuration ..."

# daemon.toml
$daemonConfig = @"
[general]
distro_name = "$DistroName"
install_dir = "$($InstallDir -replace '\\', '\\\\')"

[ipc]
pipe_name = "clawshell-service"
ui_pipe_name = "clawshell-service-ui"

[vsock]
port    = 100
enabled = true

[vmm]
distro_name = "$DistroName"
auto_start  = true

[modules]
capability_dirs = ["$($BinDir -replace '\\', '\\\\')"]
security_dirs = ["$($BinDir -replace '\\', '\\\\')"]
"@

Set-Content -Path (Join-Path $ConfigDir "daemon.toml") -Value $daemonConfig -Encoding UTF8
Write-Ok "daemon.toml"

# OpenClaw config (written inside WSL)
# Generate Gateway access token (unique per install to avoid default credential vulnerabilities)
$GatewayToken = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
$GatewayPort = 18789

if (-not $isUpgrade) {
    # Build OpenClaw config JSON (including gateway auth)
    $openclawConfig = @{
        gateway = @{
            port = $GatewayPort
            mode = "local"
            bind = "lan"
            auth = @{
                mode = "token"
                token = $GatewayToken
            }
        }
        plugins = @{
            entries = @{
                acpx = @{
                    enabled = $true
                    config = @{
                        mcpServers = @{
                            "clawshell-gui" = @{
                                command = "python3"
                                args = @("/opt/clawshell/mcp/mcp_server.py")
                            }
                        }
                    }
                }
            }
        }
        skills = @{
            load = @{
                extraDirs = @("/opt/clawshell/skills")
            }
        }
    }

    # Local model config: inject models.providers
    if ($ApiProvider -eq "local" -and $LocalModelUrl) {
        $isOllama = $LocalModelUrl -match ":11434"

        if ($isOllama) {
            $ollamaBaseUrl = $LocalModelUrl -replace '/v1$', ''
            $openclawConfig["models"] = @{
                providers = @{
                    ollama = @{
                        baseUrl = $ollamaBaseUrl
                        apiKey  = "ollama-local"
                        api     = "ollama"
                        models  = @(
                            @{
                                id            = $LocalModelId
                                name          = $LocalModelId
                                reasoning     = ([bool]($LocalModelId -match 'r1|reason|think'))
                                input         = @("text")
                                cost          = @{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0 }
                                contextWindow = 131072
                                maxTokens     = 8192
                            }
                        )
                    }
                }
            }
            $openclawConfig["agents"] = @{
                defaults = @{
                    model = @{ primary = "ollama/$LocalModelId" }
                }
            }
        } else {
            $apiBaseUrl = $LocalModelUrl.TrimEnd('/')
            if ($apiBaseUrl -notmatch '/v1$') { $apiBaseUrl += "/v1" }

            $isQwen = $LocalModelId -match 'qwen'
            $modelCompat = @{}
            if ($isQwen) {
                $modelCompat["thinkingFormat"] = "qwen"
            }

            $modelDef = @{
                id            = $LocalModelId
                name          = $LocalModelId
                reasoning     = ([bool]($LocalModelId -match 'r1|reason|think|qwen'))
                input         = @("text")
                cost          = @{ input = 0; output = 0; cacheRead = 0; cacheWrite = 0 }
                contextWindow = 32768
                maxTokens     = 8192
            }
            if ($modelCompat.Count -gt 0) {
                $modelDef["compat"] = $modelCompat
            }

            $openclawConfig["models"] = @{
                providers = @{
                    local_llm = @{
                        baseUrl                   = $apiBaseUrl
                        apiKey                    = "no-key"
                        api                       = "openai-completions"
                        injectNumCtxForOpenAICompat = $false
                        models                    = @( $modelDef )
                    }
                }
            }
            $openclawConfig["agents"] = @{
                defaults = @{
                    model = @{ primary = "local_llm/$LocalModelId" }
                }
            }
        }
    }

    $configJson = $openclawConfig | ConvertTo-Json -Depth 10

    # Write to WSL filesystem
    Invoke-WslSilent "-d $DistroName -- bash -c `"cat > /home/clawshell/.openclaw/openclaw.json`"" -InputText $configJson | Out-Null

    Write-Ok "OpenClaw config (with Gateway token)"
}

if (-not $isUpgrade -and $ApiProvider -in @("anthropic", "openai")) {
    # Write API Key via environment variable file
    if ($ApiProvider -eq "anthropic") {
        $envContent = "export ANTHROPIC_API_KEY=`"$ApiKey`""
    } else {
        $envContent = "export OPENAI_API_KEY=`"$ApiKey`""
    }

    Invoke-WslSilent "-d $DistroName -- bash -c `"cat > /home/clawshell/.clawshell-env`"" -InputText $envContent | Out-Null
    Invoke-WslSilent "-d $DistroName -- bash -c `"chown clawshell:clawshell /home/clawshell/.clawshell-env && chmod 600 /home/clawshell/.clawshell-env`"" | Out-Null

    $bashrcLine = '[[ -f ~/.clawshell-env ]] && source ~/.clawshell-env'
    Invoke-WslSilent "-d $DistroName -- bash -c `"grep -qF .clawshell-env /home/clawshell/.bashrc 2>/dev/null || echo '$bashrcLine' >> /home/clawshell/.bashrc`"" | Out-Null

    Write-Ok "OpenClaw API config"
}

if (-not $isUpgrade -and $ApiProvider -eq "local" -and $LocalModelUrl -match ":11434") {
    $envContent = "export OLLAMA_API_KEY=`"ollama-local`""

    Invoke-WslSilent "-d $DistroName -- bash -c `"cat > /home/clawshell/.clawshell-env`"" -InputText $envContent | Out-Null
    Invoke-WslSilent "-d $DistroName -- bash -c `"chown clawshell:clawshell /home/clawshell/.clawshell-env && chmod 600 /home/clawshell/.clawshell-env`"" | Out-Null

    $bashrcLine = '[[ -f ~/.clawshell-env ]] && source ~/.clawshell-env'
    Invoke-WslSilent "-d $DistroName -- bash -c `"grep -qF .clawshell-env /home/clawshell/.bashrc 2>/dev/null || echo '$bashrcLine' >> /home/clawshell/.bashrc`"" | Out-Null

    Write-Ok "Ollama environment variables"
}

# Install and start OpenClaw Gateway systemd user service
Write-Step "Installing OpenClaw Gateway service ..."
$exitCode = Invoke-WslSilent "-d $DistroName -u clawshell -- bash -lc `"openclaw daemon install >/dev/null 2>&1`""
if ($exitCode -eq 0) {
    Write-Ok "OpenClaw Gateway registered as systemd service"
} else {
    Write-Warn "OpenClaw Gateway service registration failed (exit code: $exitCode)"
    Write-Warn "You can run manually later: wsl -d $DistroName -u clawshell -- bash -lc 'openclaw daemon install'"
}

# Enable systemd linger for clawshell user so --user services auto-start without a login session
Write-Step "Enabling systemd user service autostart (loginctl enable-linger) ..."
$exitCode = Invoke-WslSilent "-d $DistroName -- bash -c `"loginctl enable-linger clawshell >/dev/null 2>&1`""
if ($exitCode -eq 0) {
    Write-Ok "systemd linger enabled (OpenClaw will auto-start when distro boots)"
} else {
    Write-Warn "loginctl enable-linger failed; OpenClaw will be started by the Windows daemon on each boot"
}

Write-Step "Starting OpenClaw Gateway ..."
$exitCode = Invoke-WslSilent "-d $DistroName -u clawshell -- bash -lc `"openclaw daemon start >/dev/null 2>&1`""
if ($exitCode -eq 0) {
    Write-Ok "OpenClaw Gateway started"
} else {
    Write-Warn "OpenClaw Gateway start failed (exit code: $exitCode)"
    Write-Warn "You can run manually later: wsl -d $DistroName -u clawshell -- bash -lc 'openclaw daemon start'"
}

# Save Gateway token to local file for reference
$tokenFilePath = Join-Path $ConfigDir "gateway-token.txt"
@"
# ClawShell OpenClaw Gateway Access Token
# Keep this safe, do not share
#
# WebUI URL: http://localhost:$GatewayPort
# Access token:
$GatewayToken
"@ | Set-Content -Path $tokenFilePath -Encoding UTF8
Write-Ok "Gateway token saved to $tokenFilePath"

# -- Register startup ------------------------------------------------------

Write-Step "Registering startup shortcut ..."

$daemonExe = Join-Path $BinDir "claw_shell_service.exe"
$configPath = Join-Path $ConfigDir "daemon.toml"

$shortcutPath = Join-Path $StartupDir "$AppName.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $daemonExe
$shortcut.Arguments = "--config `"$configPath`""
$shortcut.WorkingDirectory = $BinDir
$shortcut.Description = "$AppName Daemon"
$shortcut.Save()

Write-Ok "Startup shortcut created"

# -- Register in Add/Remove Programs --------------------------------------

Write-Step "Saving uninstall script ..."
$uninstScriptsDir = Join-Path $InstallDir "scripts"
New-Item -ItemType Directory -Path $uninstScriptsDir -Force | Out-Null
$localScriptPath = Join-Path $uninstScriptsDir "uninstall.ps1"
$scriptSaved = $false

# Method 1: Copy the script file directly (works when running as a .ps1 file)
if ($PSCommandPath -and (Test-Path $PSCommandPath -ErrorAction SilentlyContinue)) {
    try {
        Copy-Item $PSCommandPath $localScriptPath -Force
        $scriptSaved = $true
    } catch {}
}

# Method 2: Re-download from the release URL (reliable for irm | iex installs)
if (-not $scriptSaved -and $ReleaseUrl) {
    try {
        $scriptUrl = "$ReleaseUrl/install.ps1"
        & $CurlExe -s --fail -L --connect-timeout 10 -o $localScriptPath $scriptUrl 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0 -and (Test-Path $localScriptPath) -and (Get-Item $localScriptPath).Length -gt 1000) {
            $scriptSaved = $true
        }
    } catch {}
}

# Method 3: Reconstruct from the running script block (last resort)
if (-not $scriptSaved) {
    try {
        $scriptText = "#Requires -Version 5.1`r`n" + $MyInvocation.MyCommand.ScriptBlock.ToString()
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($localScriptPath, $scriptText, $utf8Bom)
        $scriptSaved = $true
    } catch {}
}

if ($scriptSaved) {
    Write-Ok "Uninstall script saved"
} else {
    Write-Warn "Could not save uninstall script"
}

Write-Step "Registering uninstall info ..."

New-Item -Path $UninstallRegKey -Force | Out-Null
$uninstallCmd = "powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$localScriptPath`" -Uninstall"

Set-ItemProperty -Path $UninstallRegKey -Name "DisplayName"     -Value $AppName
Set-ItemProperty -Path $UninstallRegKey -Name "DisplayVersion"  -Value $ResolvedVersion
Set-ItemProperty -Path $UninstallRegKey -Name "Publisher"       -Value "ClawShell"
Set-ItemProperty -Path $UninstallRegKey -Name "InstallLocation" -Value $InstallDir
Set-ItemProperty -Path $UninstallRegKey -Name "UninstallString" -Value $uninstallCmd
Set-ItemProperty -Path $UninstallRegKey -Name "NoModify"        -Value 1 -Type DWord
Set-ItemProperty -Path $UninstallRegKey -Name "NoRepair"        -Value 1 -Type DWord

Write-Ok "Registered in Settings > Apps"

# -- Clean up downloads ----------------------------------------------------

Write-Step "Cleaning download cache ..."
Remove-Item $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Ok "Download cache cleaned"

# -- Launch ----------------------------------------------------------------

Write-Banner "Starting $AppName"

Write-Step "Starting daemon ..."
Start-Process -FilePath $daemonExe -ArgumentList "--config", "`"$configPath`"" -WindowStyle Hidden
Write-Ok "Daemon started"

# UI
$uiExe = Join-Path $BinDir "claw_shell_ui.exe"
if (Test-Path $uiExe) {
    Write-Step "Starting UI ..."
    Start-Process -FilePath $uiExe -WindowStyle Hidden
    Write-Ok "UI started (check system tray)"
}

# -- Wait for OpenClaw Gateway to be ready ---------------------------------

Write-Host ""
Write-Step "Waiting for OpenClaw Gateway to initialize ..."
$gatewayReady = $false
$spinChars = @('-', '\', '|', '/')
for ($waitIdx = 0; $waitIdx -lt 20; $waitIdx++) {
    Start-Sleep -Seconds 2
    $spin = $spinChars[$waitIdx % 4]
    $elapsed = ($waitIdx + 1) * 2
    Write-Host "`r  $spin Waiting for OpenClaw Gateway (${elapsed}s) ...          " -NoNewline
    $null = & $CurlExe -s --connect-timeout 2 "http://localhost:$GatewayPort" 2>&1
    if ($LASTEXITCODE -ne 7 -and $LASTEXITCODE -ne 28) {
        $gatewayReady = $true
        break
    }
}
Write-Host "`r                                                              `r" -NoNewline

if ($gatewayReady) {
    Write-Ok "OpenClaw Gateway is ready!"
} else {
    Write-Warn "OpenClaw Gateway is still starting up."
    Write-Warn "The system tray icon may appear grey for up to a minute."
    Write-Warn "This is normal -- services are initializing in the background."
}

# -- Done ------------------------------------------------------------------

$actionText = if ($isUpgrade) { "upgrade" } else { "installation" }

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  [OK] $AppName $actionText complete!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Install path: $InstallDir" -ForegroundColor White
Write-Host "  WSL Distro:   $DistroName" -ForegroundColor White
Write-Host ""

# OpenClaw WebUI access info
Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
Write-Host "  |  OpenClaw WebUI                              |" -ForegroundColor Cyan
Write-Host "  |                                              |" -ForegroundColor Cyan
Write-Host "  |  URL:   http://localhost:$GatewayPort            |" -ForegroundColor Cyan
Write-Host "  |  Token: $GatewayToken  |" -ForegroundColor Cyan
Write-Host "  |                                              |" -ForegroundColor Cyan
Write-Host "  |  Open the URL above and enter the token.     |" -ForegroundColor Cyan
Write-Host "  +----------------------------------------------+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Token saved to: $tokenFilePath" -ForegroundColor DarkGray
Write-Host ""

if ($ApiProvider -eq "skip" -or $isUpgrade) {
    Write-Host "  API Key not configured. Set it up in the WebUI." -ForegroundColor Yellow
    Write-Host ""
}

if ($ApiProvider -eq "local" -and $LocalModelUrl) {
    Write-Host "  +----------------------------------------------+" -ForegroundColor Magenta
    Write-Host "  |  Local Model                                 |" -ForegroundColor Magenta
    Write-Host "  |                                              |" -ForegroundColor Magenta
    Write-Host "  |  URL:      $($LocalModelUrl.PadRight(35))|" -ForegroundColor Magenta
    Write-Host "  |  Model ID: $($LocalModelId.PadRight(35))|" -ForegroundColor Magenta
    Write-Host "  |                                              |" -ForegroundColor Magenta
    Write-Host "  |  Make sure the model service is running      |" -ForegroundColor Magenta
    Write-Host "  |  and accessible from WSL.                    |" -ForegroundColor Magenta
    Write-Host "  +----------------------------------------------+" -ForegroundColor Magenta
    Write-Host ""
}

Write-Host "  Management:" -ForegroundColor White
Write-Host "    - System tray icon  -- Status & quick actions" -ForegroundColor DarkGray
Write-Host "    - OpenClaw WebUI    -- AI chat & advanced settings" -ForegroundColor DarkGray
Write-Host "    - wsl -d $DistroName -- CLI (advanced users)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Uninstall:" -ForegroundColor White
Write-Host "    Settings > Apps > $AppName > Uninstall" -ForegroundColor DarkGray
Write-Host ""
