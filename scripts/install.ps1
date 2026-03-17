#Requires -Version 5.1
<#
.SYNOPSIS
    ClawShell 一键安装脚本

.DESCRIPTION
    下载并安装 ClawShell（OpenClaw + GUI 自动化能力网关）。

    安装内容：
      - ClawShell daemon + UI + 插件（Windows 侧）
      - ClawShell WSL2 虚拟机（内含 OpenClaw + MCP Server）

    安装最新版本：
      irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex

    安装指定版本（推荐固定版本时使用）：
      irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex -Version 0.1.0
      # 或者直接从该版本的 Release 下载 install.ps1，URL 本身已固定版本：
      irm https://github.com/carlos-Ng/ClawShell/releases/download/v0.1.0/install.ps1 | iex

    Release 资产说明：
      clawshell-windows-<ver>.zip  — Windows 侧所有二进制文件（daemon、vmm、ui、dll）
      clawshell-rootfs.tar.gz      — WSL2 虚拟机镜像（首次安装时下载）
      install.ps1                  — 本安装脚本（每个 Release 各自附带）

.PARAMETER Version
    指定要安装的版本号（如 0.1.0）。留空则安装最新版。

.PARAMETER Uninstall
    卸载 ClawShell

.PARAMETER Upgrade
    升级 ClawShell 组件（保留用户数据）
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

# ── 配置 ─────────────────────────────────────────────────────────────────

$ErrorActionPreference = "Stop"

$AppName        = "ClawShell"
$DistroName     = "ClawShell"
$DefaultInstDir = Join-Path $env:LOCALAPPDATA $AppName
$StartupDir     = [Environment]::GetFolderPath("Startup")
$UninstallRegKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$AppName"

# GitHub Release URL 构造
# - 无 -Version 参数：使用 releases/latest/download/
# - 有 -Version 参数：使用 releases/download/v<ver>/
if (-not $ReleaseUrl) {
    if ($Version) {
        $DefaultReleaseBase = "https://github.com/carlos-Ng/ClawShell/releases/download/v$Version"
    } else {
        $DefaultReleaseBase = "https://github.com/carlos-Ng/ClawShell/releases/latest/download"
    }
}

# Release 资产（zip 包含所有 Windows 二进制，rootfs 单独打包以便升级时跳过）
# zip 文件名含版本号，从 Release URL 推断：latest 时在下载前解析实际版本
$RootfsName = "clawshell-rootfs.tar.gz"

# zip 包内的文件列表（用于安装验证）
$WindowsBinFiles = @(
    "claw_shell_service.exe"
    "claw_shell_vmm.exe"
    "claw_shell_ui.exe"
    "capability_ax.dll"
    "security_filter.dll"
)

# ── 工具函数 ─────────────────────────────────────────────────────────────

function Write-Banner {
    param([string]$Text)
    $line = "═" * 50
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host $line -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step {
    param([string]$Text)
    Write-Host "  → $Text" -ForegroundColor White
}

function Write-Ok {
    param([string]$Text)
    Write-Host "  ✓ $Text" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Text)
    Write-Host "  ⚠ $Text" -ForegroundColor Yellow
}

function Write-Err {
    param([string]$Text)
    Write-Host "  ✗ $Text" -ForegroundColor Red
}

function Confirm-Continue {
    param([string]$Prompt = "是否继续？")
    $answer = Read-Host "$Prompt (Y/n)"
    if ($answer -and $answer -notmatch '^[Yy]') {
        Write-Host "已取消。"
        exit 0
    }
}

# ── 卸载 ─────────────────────────────────────────────────────────────────

if ($Uninstall) {
    Write-Banner "卸载 $AppName"

    # 停止进程
    Write-Step "停止 $AppName 进程 ..."
    Get-Process -Name "claw_shell_service", "claw_shell_ui" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1

    # 关闭 WSL distro
    Write-Step "关闭 WSL distro ..."
    wsl -t $DistroName 2>$null

    # 确认是否删除 VM 数据
    $removeVM = Read-Host "  是否删除 $DistroName 虚拟机及其所有数据？(y/N)"
    if ($removeVM -match '^[Yy]') {
        Write-Step "注销 WSL distro ..."
        wsl --unregister $DistroName 2>$null
        Write-Ok "虚拟机已删除"
    } else {
        Write-Warn "虚拟机保留（可手动执行 wsl --unregister $DistroName）"
    }

    # 删除启动项
    $startupLink = Join-Path $StartupDir "$AppName.lnk"
    if (Test-Path $startupLink) {
        Remove-Item $startupLink -Force
        Write-Ok "开机启动项已删除"
    }

    # 确定安装目录
    $instDir = $DefaultInstDir
    if (Test-Path $UninstallRegKey) {
        $regInstDir = (Get-ItemProperty $UninstallRegKey -ErrorAction SilentlyContinue).InstallLocation
        if ($regInstDir) { $instDir = $regInstDir }
    }

    # 删除安装文件
    if (Test-Path $instDir) {
        Write-Step "删除安装目录 $instDir ..."
        Remove-Item $instDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Ok "安装文件已删除"
    }

    # 删除注册表
    if (Test-Path $UninstallRegKey) {
        Remove-Item $UninstallRegKey -Force
        Write-Ok "注册表项已清除"
    }

    Write-Host ""
    Write-Ok "$AppName 已卸载"
    exit 0
}

# ── 环境检查 ─────────────────────────────────────────────────────────────

Write-Banner "$AppName 安装程序 v$((Get-Date).ToString('yyyy.M.d'))"

Write-Step "检查系统环境 ..."

# Windows 版本
$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Build -lt 19041) {
    Write-Err "需要 Windows 10 2004 (Build 19041) 或更高版本"
    Write-Err "当前版本: $($osVersion.ToString())"
    exit 1
}
Write-Ok "Windows 版本: $($osVersion.ToString())"

# curl.exe（下载工具，Windows 10 17063+ 自带）
$CurlExe = (Get-Command "curl.exe" -ErrorAction SilentlyContinue)?.Source
if (-not $CurlExe) {
    Write-Err "未找到 curl.exe"
    Write-Host ""
    Write-Host "  curl.exe 是 Windows 10 (Build 17063) 及以上版本的内置工具。" -ForegroundColor Yellow
    Write-Host "  如果你的系统没有，可以从以下地址下载安装：" -ForegroundColor Yellow
    Write-Host "    https://curl.se/windows/" -ForegroundColor White
    Write-Host "  安装后请重新运行此脚本。" -ForegroundColor Yellow
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
if ($LASTEXITCODE -eq 0 -or ($wslStatus -match "默认版本|Default Version")) {
    $wslInstalled = $true
}

if (-not $wslInstalled) {
    Write-Warn "WSL2 未安装或未启用"
    Write-Host ""
    Write-Host "  需要先安装 WSL2。在管理员 PowerShell 中执行：" -ForegroundColor Yellow
    Write-Host "    wsl --install --no-distribution" -ForegroundColor White
    Write-Host "  安装完成后重启电脑，然后重新运行此安装脚本。" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Ok "WSL2 已就绪"

# 检查是否已安装
$existingDistro = wsl -l -q 2>$null | Where-Object { $_ -match "^$DistroName$" }
$isUpgrade = $false

if ($existingDistro -and -not $Upgrade) {
    Write-Warn "$DistroName 虚拟机已存在"
    Write-Host ""
    Write-Host "  选项：" -ForegroundColor Yellow
    Write-Host "    1) 升级（保留数据，更新组件）" -ForegroundColor White
    Write-Host "    2) 全新安装（删除现有数据）" -ForegroundColor White
    Write-Host "    3) 取消" -ForegroundColor White
    $choice = Read-Host "  请选择 (1/2/3)"
    switch ($choice) {
        "1" { $isUpgrade = $true }
        "2" {
            Write-Step "注销现有 distro ..."
            wsl -t $DistroName 2>$null
            wsl --unregister $DistroName 2>$null
            Write-Ok "已清除"
        }
        default { Write-Host "已取消。"; exit 0 }
    }
}

if ($Upgrade) { $isUpgrade = $true }

# ── 安装路径 ─────────────────────────────────────────────────────────────

if (-not $InstallDir) {
    # 如果已注册，使用已有路径
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

Write-Ok "安装路径: $InstallDir"

# ── 下载 ─────────────────────────────────────────────────────────────────

if (-not $isUpgrade) {
    Write-Banner "下载组件"
} else {
    Write-Banner "下载更新"
}

if (-not $ReleaseUrl) { $ReleaseUrl = $DefaultReleaseBase }

New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null

function Invoke-Download {
    param([string]$Url, [string]$Dest, [string]$Desc)
    Write-Step "下载 $Desc ..."
    Write-Host ""
    # -L  跟随重定向（GitHub Release 有 302 跳转）
    # -#  进度条模式
    # -C- 断点续传（若目标文件已存在则从中断处继续）
    # --retry 3  网络故障自动重试 3 次
    # --retry-delay 2  重试间隔 2 秒
    & $CurlExe -L "-#" -C - --retry 3 --retry-delay 2 -o $Dest $Url
    Write-Host ""
    if ($LASTEXITCODE -ne 0) {
        Write-Err "下载失败: $Desc (curl 退出码: $LASTEXITCODE)"
        Write-Err "  URL: $Url"
        Write-Host ""
        Write-Host "  若无法访问 GitHub，可先通过浏览器下载以下文件到同一目录：" -ForegroundColor Yellow
        Write-Host "    - clawshell-windows-$ResolvedVersion.zip" -ForegroundColor White
        Write-Host "    - clawshell-rootfs.tar.gz（首次安装）" -ForegroundColor White
        Write-Host ""
        exit 1
    }
    Write-Ok $Desc
}

# 解析实际版本号（用于构造带版本号的 zip 文件名）
# 指定了 -Version 则直接使用；否则通过 GitHub API 查询 latest release tag
$ResolvedVersion = $Version
if (-not $ResolvedVersion) {
    Write-Step "查询最新版本号 ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $apiResp = Invoke-RestMethod -Uri "https://api.github.com/repos/carlos-Ng/ClawShell/releases/latest" -ErrorAction Stop
        $ResolvedVersion = $apiResp.tag_name -replace '^v', ''
        Write-Ok "最新版本: $ResolvedVersion"
    } catch {
        Write-Warn "无法查询 GitHub API，将直接尝试下载（需要网络可访问 GitHub）"
        $ResolvedVersion = "latest"
    }
}

# zip 文件名含版本号（与 CMake release target 输出一致）
$WindowsZipName = if ($ResolvedVersion -eq "latest") {
    "clawshell-windows.zip"
} else {
    "clawshell-windows-$ResolvedVersion.zip"
}

# 下载 Windows 二进制 zip 包（升级和全新安装都需要）
$zipDest = Join-Path $DownloadDir $WindowsZipName
Invoke-Download -Url "$ReleaseUrl/$WindowsZipName" -Dest $zipDest -Desc "Windows 组件包 ($WindowsZipName)"

# 首次安装时下载 rootfs（升级跳过）
if (-not $isUpgrade) {
    $rootfsDest = Join-Path $DownloadDir $RootfsName
    Invoke-Download -Url "$ReleaseUrl/$RootfsName" -Dest $rootfsDest -Desc "VM 镜像 ($RootfsName)"
}

# ── 配置向导 ─────────────────────────────────────────────────────────────

if (-not $isUpgrade) {
    Write-Banner "配置向导"

    # API Provider
    if (-not $ApiProvider) {
        Write-Host "  选择 AI 模型提供商：" -ForegroundColor White
        Write-Host "    1) Anthropic (Claude)  — 推荐" -ForegroundColor White
        Write-Host "    2) OpenAI (GPT)" -ForegroundColor White
        Write-Host "    3) 本地模型 (llama.cpp / Ollama / OpenAI 兼容)" -ForegroundColor White
        Write-Host "    4) 其他（稍后在 OpenClaw WebUI 中配置）" -ForegroundColor White
        $providerChoice = Read-Host "  请选择 (1/2/3/4)"
        switch ($providerChoice) {
            "1" { $ApiProvider = "anthropic" }
            "2" { $ApiProvider = "openai" }
            "3" { $ApiProvider = "local" }
            default { $ApiProvider = "skip" }
        }
    }

    # Local Model 配置
    if ($ApiProvider -eq "local") {
        Write-Host ""
        Write-Host "  ┌─────────────────────────────────────────────┐" -ForegroundColor Cyan
        Write-Host "  │  本地模型配置                               │" -ForegroundColor Cyan
        Write-Host "  │                                             │" -ForegroundColor Cyan
        Write-Host "  │  支持所有 OpenAI 兼容 API 的推理服务：      │" -ForegroundColor Cyan
        Write-Host "  │    • llama.cpp (--host 0.0.0.0 -p 8080)    │" -ForegroundColor Cyan
        Write-Host "  │    • Ollama (http://host:11434)             │" -ForegroundColor Cyan
        Write-Host "  │    • vLLM / SGLang / LocalAI / LM Studio   │" -ForegroundColor Cyan
        Write-Host "  └─────────────────────────────────────────────┘" -ForegroundColor Cyan
        Write-Host ""

        if (-not $LocalModelUrl) {
            Write-Host "  请输入模型服务地址" -ForegroundColor White
            Write-Host "  示例: http://192.168.1.100:8080  (llama.cpp)" -ForegroundColor DarkGray
            Write-Host "  示例: http://192.168.1.100:11434 (Ollama)" -ForegroundColor DarkGray
            $LocalModelUrl = Read-Host "  模型服务地址"
        }

        if (-not $LocalModelUrl) {
            Write-Warn "未输入模型地址，稍后可在 OpenClaw WebUI 中配置"
            $ApiProvider = "skip"
        } else {
            # 自动检测 Ollama vs OpenAI 兼容
            $isOllama = $LocalModelUrl -match ":11434"

            if (-not $LocalModelId) {
                Write-Host ""
                Write-Host "  请输入模型 ID（留空使用默认值）" -ForegroundColor White
                if ($isOllama) {
                    Write-Host "  示例: qwen3.5:27b, glm-4.7-flash, deepseek-r1:32b" -ForegroundColor DarkGray
                    $defaultModelId = "glm-4.7-flash"
                } else {
                    Write-Host "  示例: qwen3.5, glm-4.7, llama-3.3-70b" -ForegroundColor DarkGray
                    $defaultModelId = "default"
                }
                $LocalModelId = Read-Host "  模型 ID (默认: $defaultModelId)"
                if (-not $LocalModelId) { $LocalModelId = $defaultModelId }
            }

            Write-Ok "本地模型配置就绪 ($LocalModelUrl → $LocalModelId)"
        }
    }

    # API Key（云端提供商）
    if ($ApiProvider -in @("anthropic", "openai") -and -not $ApiKey) {
        Write-Host ""
        if ($ApiProvider -eq "anthropic") {
            Write-Host "  请输入 Anthropic API Key" -ForegroundColor White
            Write-Host "  (从 https://console.anthropic.com/account/keys 获取)" -ForegroundColor DarkGray
        } else {
            Write-Host "  请输入 OpenAI API Key" -ForegroundColor White
            Write-Host "  (从 https://platform.openai.com/api-keys 获取)" -ForegroundColor DarkGray
        }
        $ApiKey = Read-Host "  API Key"

        if (-not $ApiKey) {
            Write-Warn "未输入 API Key，稍后可在 OpenClaw WebUI 中配置"
            $ApiProvider = "skip"
        }
    }

    if ($ApiProvider -ne "skip") {
        Write-Ok "API 配置就绪 ($ApiProvider)"
    }
}

# ── 安装文件 ─────────────────────────────────────────────────────────────

Write-Banner "安装"

# 创建目录
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null
New-Item -ItemType Directory -Path $DistroDir -Force | Out-Null

# 停止已运行的进程
Write-Step "停止旧进程 ..."
Get-Process -Name "claw_shell_service", "claw_shell_ui" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# 解压 Windows 组件包
Write-Step "解压 Windows 组件包 ..."
$zipPath = Join-Path $DownloadDir $WindowsZipName
Expand-Archive -Path $zipPath -DestinationPath $BinDir -Force
Write-Ok "程序文件已安装"

# ── 导入 WSL Distro ──────────────────────────────────────────────────────

if (-not $isUpgrade) {
    Write-Step "导入 WSL 虚拟机 ..."
    $rootfsPath = Join-Path $DownloadDir $RootfsName

    if (-not (Test-Path $rootfsPath)) {
        Write-Err "rootfs 文件不存在: $rootfsPath"
        exit 1
    }

    wsl --import $DistroName $DistroDir $rootfsPath
    if ($LASTEXITCODE -ne 0) {
        Write-Err "WSL 导入失败"
        exit 1
    }
    Write-Ok "虚拟机已导入"
}

# ── 写入配置 ─────────────────────────────────────────────────────────────

Write-Step "写入配置 ..."

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

# OpenClaw 配置（写入 WSL 内部）
# 生成 Gateway 访问令牌（每次安装唯一，避免默认口令漏洞）
$GatewayToken = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
$GatewayPort = 18789

if (-not $isUpgrade) {
    # 构建 OpenClaw 配置 JSON（含 gateway 认证配置）
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

    # 本地模型配置：注入 models.providers
    if ($ApiProvider -eq "local" -and $LocalModelUrl) {
        $isOllama = $LocalModelUrl -match ":11434"

        if ($isOllama) {
            # Ollama: 使用原生 API，自动发现模型
            $ollamaBaseUrl = $LocalModelUrl -replace '/v1$', ''  # 去掉 /v1
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
            # llama.cpp / vLLM / 其他 OpenAI 兼容服务
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

    # 写入 WSL 文件系统
    $configJson | wsl -d $DistroName -- bash -c 'cat > /home/clawshell/.openclaw/openclaw.json'

    Write-Ok "OpenClaw 配置（含 Gateway 令牌）"
}

if (-not $isUpgrade -and $ApiProvider -in @("anthropic", "openai")) {
    # 写入 API Key（通过环境变量文件）
    if ($ApiProvider -eq "anthropic") {
        $envContent = "export ANTHROPIC_API_KEY=`"$ApiKey`""
    } else {
        $envContent = "export OPENAI_API_KEY=`"$ApiKey`""
    }

    $envContent | wsl -d $DistroName -- bash -c 'cat > /home/clawshell/.clawshell-env'
    wsl -d $DistroName -- bash -c 'chown clawshell:clawshell /home/clawshell/.clawshell-env && chmod 600 /home/clawshell/.clawshell-env'

    # 让 .bashrc 加载环境变量
    $bashrcLine = '[[ -f ~/.clawshell-env ]] && source ~/.clawshell-env'
    $bashrcLine | wsl -d $DistroName -- bash -c 'grep -qF ".clawshell-env" /home/clawshell/.bashrc 2>/dev/null || cat >> /home/clawshell/.bashrc'

    Write-Ok "OpenClaw API 配置"
}

if (-not $isUpgrade -and $ApiProvider -eq "local" -and $LocalModelUrl -match ":11434") {
    # Ollama 需要设置 OLLAMA_API_KEY 环境变量（任意值即可）
    $envContent = "export OLLAMA_API_KEY=`"ollama-local`""

    $envContent | wsl -d $DistroName -- bash -c 'cat > /home/clawshell/.clawshell-env'
    wsl -d $DistroName -- bash -c 'chown clawshell:clawshell /home/clawshell/.clawshell-env && chmod 600 /home/clawshell/.clawshell-env'

    $bashrcLine = '[[ -f ~/.clawshell-env ]] && source ~/.clawshell-env'
    $bashrcLine | wsl -d $DistroName -- bash -c 'grep -qF ".clawshell-env" /home/clawshell/.bashrc 2>/dev/null || cat >> /home/clawshell/.bashrc'

    Write-Ok "Ollama 环境变量配置"
}

# 安装 OpenClaw Gateway 为 systemd 用户服务（VM 启动时自动运行 WebUI）
Write-Step "安装 OpenClaw Gateway 服务 ..."
try {
    wsl -d $DistroName -- su -l clawshell -c "openclaw daemon install 2>&1" | Out-Null
    Write-Ok "OpenClaw Gateway 已注册为 systemd 服务"
} catch {
    Write-Warn "OpenClaw Gateway 服务注册失败，可稍后手动执行: wsl -d $DistroName -- su -l clawshell -c 'openclaw daemon install'"
}

# 保存 Gateway 令牌到本地文件（方便用户后续查看）
$tokenFilePath = Join-Path $ConfigDir "gateway-token.txt"
@"
# ClawShell OpenClaw Gateway 访问令牌
# 请妥善保管，切勿泄露
#
# WebUI 地址: http://localhost:$GatewayPort
# 访问令牌:
$GatewayToken
"@ | Set-Content -Path $tokenFilePath -Encoding UTF8
Write-Ok "Gateway 令牌已保存至 $tokenFilePath"

# ── 注册开机启动 ─────────────────────────────────────────────────────────

Write-Step "注册开机启动 ..."

$daemonExe = Join-Path $BinDir "claw_shell_service.exe"
$configPath = Join-Path $ConfigDir "daemon.toml"

# 创建快捷方式到 Startup 文件夹
$shortcutPath = Join-Path $StartupDir "$AppName.lnk"
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $daemonExe
$shortcut.Arguments = "--config `"$configPath`""
$shortcut.WorkingDirectory = $BinDir
$shortcut.Description = "$AppName Daemon"
$shortcut.Save()

Write-Ok "开机启动项已创建"

# ── 注册到「添加/删除程序」────────────────────────────────────────────────

Write-Step "注册卸载信息 ..."

New-Item -Path $UninstallRegKey -Force | Out-Null
$uninstallCmd = "powershell.exe -ExecutionPolicy Bypass -Command `"& { irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex } -Uninstall`""

Set-ItemProperty -Path $UninstallRegKey -Name "DisplayName"     -Value $AppName
Set-ItemProperty -Path $UninstallRegKey -Name "DisplayVersion"  -Value $ResolvedVersion
Set-ItemProperty -Path $UninstallRegKey -Name "Publisher"       -Value "ClawShell"
Set-ItemProperty -Path $UninstallRegKey -Name "InstallLocation" -Value $InstallDir
Set-ItemProperty -Path $UninstallRegKey -Name "UninstallString" -Value $uninstallCmd
Set-ItemProperty -Path $UninstallRegKey -Name "NoModify"        -Value 1 -Type DWord
Set-ItemProperty -Path $UninstallRegKey -Name "NoRepair"        -Value 1 -Type DWord

Write-Ok "已注册到「设置 → 应用」"

# ── 清理下载文件 ─────────────────────────────────────────────────────────

Write-Step "清理下载缓存 ..."
Remove-Item $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Ok "下载缓存已清理"

# ── 启动 ─────────────────────────────────────────────────────────────────

Write-Banner "启动 $AppName"

Write-Step "启动 daemon ..."
Start-Process -FilePath $daemonExe -ArgumentList "--config", "`"$configPath`"" -WindowStyle Hidden
Write-Ok "daemon 已启动"

# UI
$uiExe = Join-Path $BinDir "claw_shell_ui.exe"
if (Test-Path $uiExe) {
    Write-Step "启动 UI ..."
    Start-Process -FilePath $uiExe -WindowStyle Hidden
    Write-Ok "UI 已启动（查看系统托盘）"
}

# ── 完成 ─────────────────────────────────────────────────────────────────

$actionText = if ($isUpgrade) { "升级" } else { "安装" }

Write-Host ""
Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  ✓ $AppName ${actionText}完成！" -ForegroundColor Green
Write-Host "══════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  安装路径:   $InstallDir" -ForegroundColor White
Write-Host "  WSL Distro: $DistroName" -ForegroundColor White
Write-Host ""

# OpenClaw WebUI 访问信息（醒目展示）
Write-Host "  ┌──────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │  OpenClaw WebUI                              │" -ForegroundColor Cyan
Write-Host "  │                                              │" -ForegroundColor Cyan
Write-Host "  │  地址:  http://localhost:$GatewayPort            │" -ForegroundColor Cyan
Write-Host "  │  令牌:  $GatewayToken  │" -ForegroundColor Cyan
Write-Host "  │                                              │" -ForegroundColor Cyan
Write-Host "  │  在浏览器中打开上述地址，输入令牌即可使用    │" -ForegroundColor Cyan
Write-Host "  └──────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""
Write-Host "  令牌已保存至: $tokenFilePath" -ForegroundColor DarkGray
Write-Host ""

if ($ApiProvider -eq "skip" -or $isUpgrade) {
    Write-Host "  API Key 未配置，请在 WebUI 中设置" -ForegroundColor Yellow
    Write-Host ""
}

if ($ApiProvider -eq "local" -and $LocalModelUrl) {
    Write-Host "  ┌──────────────────────────────────────────────┐" -ForegroundColor Magenta
    Write-Host "  │  本地模型                                    │" -ForegroundColor Magenta
    Write-Host "  │                                              │" -ForegroundColor Magenta
    Write-Host "  │  服务地址: $($LocalModelUrl.PadRight(35))│" -ForegroundColor Magenta
    Write-Host "  │  模型 ID:  $($LocalModelId.PadRight(35))│" -ForegroundColor Magenta
    Write-Host "  │                                              │" -ForegroundColor Magenta
    Write-Host "  │  请确保模型服务已启动并可从 WSL 访问         │" -ForegroundColor Magenta
    Write-Host "  └──────────────────────────────────────────────┘" -ForegroundColor Magenta
    Write-Host ""
}

Write-Host "  管理方式:" -ForegroundColor White
Write-Host "    • 系统托盘图标    — 查看状态、快捷操作" -ForegroundColor DarkGray
Write-Host "    • OpenClaw WebUI  — AI 对话、高级设置" -ForegroundColor DarkGray
Write-Host "    • wsl -d $DistroName — 命令行（高级用户）" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  卸载:" -ForegroundColor White
Write-Host "    设置 → 应用 → $AppName → 卸载" -ForegroundColor DarkGray
Write-Host ""
