# ClawShell

ClawShell 是为 **AI Agent** 设计的**宿主机侧能力网关**。它使用虚拟化技术将 AI Agent 隔离在独立环境中运行，同时将其能力安全、可控地延伸到宿主机，使 Agent 能够在用户授权与审查下操作真实桌面。

**核心理念**：AI Agent 运行在隔离环境中，通过 ClawShell 这扇受控的窗户访问宿主机；所有操作经安全网关审查，用户始终掌握最终决策权。

---

## 项目愿景

系统由两个隔离域构成：

| 域 | 组成 | 职责 |
|----|------|------|
| **隔离环境** | AI Agent + MCP Client | Agent 在虚拟化环境中运行，无法直接访问宿主机 |
| **宿主机** | ClawShell daemon + 能力插件 + WinForms UI | 接收 Agent 请求，经安全审查后执行 GUI 操作 |

Agent 想做任何事，必须经过 ClawShell 的审批。安全网关运行在宿主机上，独立于 Agent，即使 Agent 被劫持，攻击者能发出的也只是「请求」，能否执行由宿主机单独决定。

---

## 特性

- **虚拟化隔离** — AI Agent 运行在独立 WSL2 环境中，无法直接访问宿主机，所有操作经 ClawShell 网关审批
- **能力延伸** — 将宿主机 GUI 能力以 MCP Tool 形式安全暴露给 Agent，支持窗口枚举、UI 树、点击、输入等
- **结构化 GUI 描述** — 使用 UI Automation 输出 AXT 紧凑文本，无需截图，纯文本模型即可理解
- **安全网关** — 操作前/后双向审查，危险操作需用户确认，用户始终掌握最终决策权
- **意图指纹缓存** — 用户勾选「本任务内不再询问」后，相同类型操作自动放行，减少重复弹窗
- **任务生命周期管理** — 每次 Agent 会话对应一个任务，授权缓存随任务结束自动清除，防止权限跨任务扩散
- **UI 事件总线** — WinForms UI 通过 Channel 2 实时接收任务状态、操作日志与确认请求
- **C++ 实现** — 宿主机 daemon 单一二进制分发，无需 Python 运行时
- **MCP 协议** — 兼容 Claude Desktop、Cursor、OpenClaw 等 MCP 客户端

---

## 架构概览

```
╔══════════════════════════════════════════════════════════════╗
║  隔离环境（WSL2 虚拟机）                                      ║
║                                                              ║
║  ┌────────────────────────────────────────────────────────┐  ║
║  │  AI Agent（OpenClaw / Claude Desktop / Cursor 等）      │  ║
║  │  接收 GUI 描述 → 决策 → 发出操作意图                     │  ║
║  └────────────────────────────┬───────────────────────────┘  ║
║                               │ MCP (stdio)                  ║
║                               ▼                              ║
║  ┌────────────────────────────────────────────────────────┐  ║
║  │  mcp_server.py — MCP 协议桥接                           │  ║
║  │  将 Tool 调用通过 AF_VSOCK 转发至宿主机                  │  ║
║  └────────────────────────────┬───────────────────────────┘  ║
║                               │ Channel 3（AF_VSOCK）        ║
╚═══════════════════════════════╪══════════════════════════════╝
                                │
╔═══════════════════════════════╪══════════════════════════════╗
║  宿主机                        ▼                              ║
║                                                              ║
║  ┌────────────────────────────────────────────────────────┐  ║
║  │  vmm.exe — VM 生命周期管理                               │  ║
║  │  启动/停止/监控 WSL distro，watchdog 自动重启            │  ║
║  └──────────────────────────────────────────────────────  ║
║                                                              ║
║  ┌────────────────────────────────────────────────────────┐  ║
║  │  crew_shell_service (daemon)                            │  ║
║  │  ├── VsockServer — Channel 3 接收 VM 请求               │  ║
║  │  ├── TaskRegistry — 任务生命周期 + 意图指纹授权缓存      │  ║
║  │  ├── SecurityChain — 安全审查链（入站 + 出站）           │  ║
║  │  ├── CapabilityService — 能力路由 + 确认流程             │  ║
║  │  ├── capability_ax.dll — GUI 识别 + 操作执行 (UIA)      │  ║
║  │  └── UIService — Channel 2 事件总线                     │  ║
║  └──────────────────────┬─────────────────────────────────┘  ║
║                         │ Channel 2（Named Pipe）             ║
║                         ▼ status/task/op_log/confirm         ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │  ClawShell UI (WinForms)                                 │  ║
║  │  系统托盘 · 任务监控 · 确认弹窗                           │  ║
║  └─────────────────────────────────────────────────────────┘  ║
╚══════════════════════════════════════════════════════════════╝
```

> **Phase 1 兼容**：MCP Server 也可直接运行在宿主机，通过 Named Pipe 与 daemon 通信，用于开发调试与 Claude Desktop 等本地 MCP 客户端集成。

---

## 快速安装（推荐）

### 系统要求

| 要求 | 说明 |
|------|------|
| Windows 10 2004 (Build 19041) 或更高 | WSL2 最低要求 |
| WSL2 已启用 | 见下方说明 |
| 硬盘空间 ≥ 4 GB | rootfs + 二进制文件 |
| 内存 ≥ 8 GB | WSL2 + Agent 运行 |

**WSL2 未安装时**，在管理员 PowerShell 中执行：

```powershell
wsl --install --no-distribution
```

安装完成后**重启电脑**，再继续。

---

### 一键安装

在 **PowerShell** 中执行（无需管理员权限）：

```powershell
irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex
```

安装程序会自动完成：

1. 检查 WSL2 环境
2. 下载 ClawShell daemon、UI、插件、VM 镜像
3. 导入 WSL2 虚拟机（含 OpenClaw + MCP Server）
4. 配置 AI 后端（API Key 或本地模型）
5. 生成随机 Gateway Token
6. 配置开机自启
7. 启动 ClawShell

安装结束后，终端会显示 OpenClaw WebUI 地址与访问 Token，记下备用。

---

### 升级

```powershell
irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex -Upgrade
```

升级保留用户数据（WSL2 distro、配置、Token），仅更新二进制组件。

---

### 卸载

```powershell
irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex -Uninstall
```

或通过「设置 → 应用 → ClawShell」卸载。

---

## 首次使用

### 1. 确认 ClawShell 正在运行

安装完成后，系统托盘会出现 ClawShell 图标。双击图标打开主界面，确认状态显示为「已连接」。

若托盘图标不存在，手动启动：

```powershell
Start-Process "$env:LOCALAPPDATA\ClawShell\bin\ClawShellUI.exe"
```

### 2. 访问 OpenClaw

打开浏览器，访问：

```
http://localhost:18789
```

输入安装时显示的 Token，即可进入 OpenClaw WebUI，开始与 AI Agent 对话。

Token 保存在：

```
%LOCALAPPDATA%\ClawShell\gateway-token.txt
```

### 3. 与 Claude Desktop 集成（可选）

如需在 Claude Desktop 中直接使用 ClawShell GUI 能力（宿主机直连模式），在 `%APPDATA%\Claude\claude_desktop_config.json` 中添加：

```json
{
  "mcpServers": {
    "clawshell": {
      "command": "python",
      "args": ["%LOCALAPPDATA%\\ClawShell\\mcp\\mcp_server.py"]
    }
  }
}
```

### 4. 与 Cursor 集成（可选）

在 Cursor 的 MCP Settings 中添加：

```json
{
  "clawshell": {
    "command": "python",
    "args": ["%LOCALAPPDATA%\\ClawShell\\mcp\\mcp_server.py"]
  }
}
```

---

## 安全确认界面

当 Agent 发起需要用户授权的操作（如点击、输入等），ClawShell UI 会弹出确认对话框：

- **允许** — 本次操作执行，继续询问
- **允许（本任务内不再询问）** — 相同类型操作自动放行，任务结束后失效
- **拒绝** — 拒绝本次操作，Agent 收到错误响应

---

## 支持的操作

| 操作 | 说明 |
|------|------|
| `list_windows` | 枚举可访问的顶层窗口 |
| `get_ui_tree` | 获取窗口的 UI 元素树（AXT 格式） |
| `click` / `double_click` / `right_click` | 点击元素 |
| `set_value` | 向输入框写入文本 |
| `focus` | 将焦点移至元素 |
| `scroll` | 滚动可滚动区域 |
| `key_press` / `key_combo` | 按键与组合键 |
| `activate_window` | 激活窗口到前台 |

---

## IPC 通道

ClawShell 使用三条独立通道：

### Channel 1：vmm.exe ↔ Daemon（VM 管理）

vmm.exe 与 daemon 之间的控制通道（Named Pipe）。

### Channel 2：Daemon ↔ UI（事件总线）

| 消息类型 | 方向 | 说明 |
|---------|------|------|
| `status` | Daemon→UI | daemon 连接状态 |
| `task_begin` | Daemon→UI | 任务开始通知 |
| `task_end` | Daemon→UI | 任务结束通知 |
| `op_log` | Daemon→UI | 操作日志（allowed / confirmed / denied） |
| `confirm` | Daemon→UI | 需用户确认的操作请求 |
| `confirm_response` | UI→Daemon | 用户确认结果（含 `trust_fingerprint`） |

### Channel 3：VM → Daemon（能力调用）

mcp_server.py 通过 AF_VSOCK 直连 daemon，使用 FrameCodec 帧协议传输：

| 消息类型 | 方向 | 说明 |
|---------|------|------|
| `beginTask` | VM→Daemon | 开始一个 Agent 任务，返回 `task_id` |
| `endTask` | VM→Daemon | 结束任务 |
| `capability` | VM→Daemon | 调用能力（携带 `task_id`、操作名、参数） |
| `capability_result` | Daemon→VM | 能力调用结果 |

---

## 安全机制

### 安全审查链

```
请求到达
  │
  ▼ preHook（执行前）
  │  Deny        → 拒绝，不执行，推送 op_log(denied/rule_deny)
  │  NeedConfirm → 检查意图指纹缓存
  │                └─ 命中  → 直接放行，推送 op_log(allowed/fingerprint_cache)
  │                └─ 未命中 → 向 UI 弹出确认弹窗
  │                           └─ 拒绝 → 推送 op_log(denied/user_confirm)
  │                           └─ 确认 → 可选缓存指纹，推送 op_log(confirmed/user_confirm)
  │  Pass        → 继续
  │
  ▼ 能力执行
  │
  ▼ postHook（执行后）
  │  可对返回内容脱敏
  │
  ▼ 返回结果，推送 op_log(allowed/auto_allow)
```

**裁决合并**：多个安全模块按优先级执行，最严格者胜出（Deny > NeedConfirm > Pass > Skip）。

### 安全规则配置

安全规则在 `config/security_filter_rules.toml` 中配置：

```toml
# 拒绝规则
[[deny]]
capability = "capability_ax"
operations = ["key_combo"]
params_field = "keys"
params_patterns = ["Win", "Cmd"]
reason = "Win/Cmd 组合键可触发系统级操作，已拦截"

# 确认规则（需用户确认）
[[confirm]]
capability = "capability_ax"
operations = ["click", "double_click", "right_click"]
reason = "GUI 点击操作需用户确认"
```

---

## 配置说明

配置文件位于安装目录的 `config\clawshell.toml`：

```toml
[daemon]
socket_path      = "\\\\.\\pipe\\crew-shell-service"
thread_pool_size = 4
log_level        = "info"
module_dir       = "lib"

[ui]
pipe_path    = "\\\\.\\pipe\\crew-shell-service-ui"
timeout_mode = "timeout_deny"   # wait_forever / timeout_deny / timeout_allow
timeout_secs = 60

[vsock]
port    = 100
enabled = true

[vmm]
distro_name = "ClawShell"
auto_start  = true

[[modules]]
name = "capability_ax"

[[modules]]
name       = "security_filter"
priority   = 10
rules_file = "config\\security_filter_rules.toml"
```

### timeout_mode 说明

| 值 | 行为 |
|----|------|
| `timeout_deny` | 超时后自动拒绝（默认，安全优先） |
| `timeout_allow` | 超时后自动允许（应用优先） |
| `wait_forever` | 无限等待用户响应 |

---

## 开发者：从源码构建

### 环境要求

- Windows 10 或更高版本
- CMake 3.20+
- Visual Studio 2022（或 Ninja + MSVC）
- C++20 编译器
- .NET 8 SDK（构建 UI）

### 构建步骤

```powershell
# 配置
cmake -S . -B build

# 编译（Debug）
cmake --build build

# 生成 dist 发布目录
cmake --build build --target dist
```

### 构建产物

| 路径 | 说明 |
|------|------|
| `build\Debug\crew_shell_service.exe` | 主 daemon |
| `build\Debug\vmm.exe` | VM 管理器 |
| `build\daemon-service\Debug\capability_ax.dll` | AX 能力模块 |
| `build\Debug\security_filter.dll` | 安全过滤模块 |
| `ui\bin\Release\net8.0-windows\win-x64\publish\ClawShellUI.exe` | 托盘 UI |
| `dist\` | 发布目录（`--target dist` 后生成） |

### 开发模式运行

```powershell
# 启动 daemon（前台模式，日志输出到控制台）
.\build\Debug\crew_shell_service.exe -f

# 另开终端启动 UI
.\ui\bin\Release\net8.0-windows\win-x64\publish\ClawShellUI.exe
```

项目根目录的 `clawshell.toml` 的 `module_dir` 指向 `build\daemon-service`，适合开发调试。

### 测试工具

```powershell
# 安装 Python 依赖
pip install -r tools\requirements.txt

# AX 测试客户端（直连 Channel 1，需先启动 daemon）
python tools\ax_test_client.py

# 批量执行测试脚本
python tools\ax_test_client.py -f tools\scripts\01_normal_task.txt
```

---

## 构建 VM rootfs

rootfs 包含 WSL2 虚拟机镜像（Debian + OpenClaw + ClawShell MCP Server）。

```bash
# 在 Linux/WSL2 环境中执行
bash scripts/build-rootfs.sh
```

生成 `clawshell-rootfs.tar.gz`，上传到 GitHub Release 供 `install.ps1` 下载。

---

## 项目结构

```
ClawShell/
├── include/                    # 公开头文件
│   ├── common/                 # 错误码、日志、类型
│   ├── core/base/              # 模块接口、安全链、能力服务
│   ├── core/                   # TaskRegistry
│   ├── ipc/                    # IPC 接口、UIService、FrameCodec
│   └── vmm/                    # VMManager、VsockServer 接口
├── daemon-service/             # C++ 实现
│   ├── core/                   # CapabilityService、TaskRegistry、SecurityChain
│   ├── daemon/                 # main.cc、daemon.cc、vmm_launcher
│   ├── capability/ax/          # AX 能力模块（Windows UI Automation）
│   ├── security/filter/        # 基于 TOML 规则的安全过滤模块
│   └── ipc/                    # Named Pipe + UIService + FrameCodec
├── vmm/                        # VM 管理器（vmm.exe）
├── ui/                         # ClawShell WinForms UI（C# .NET 8）
├── mcp/                        # MCP Server（Python，运行在 VM 内）
│   ├── server/                 # mcp_server.py、vsock_client.py
│   └── client/clawshell-gui/   # OpenClaw skill（clawshell-gui）
├── config/                     # 配置文件模板
├── scripts/                    # build-rootfs.sh、install.ps1
├── tools/                      # 开发测试工具（Python）
├── tests/                      # 单元测试
├── third_party/                # 第三方 header-only 库
└── clawshell.toml              # 项目根开发配置
```

---

## 技术栈

| 组件 | 选型 |
|------|------|
| 宿主机 daemon | C++20 / CMake / MSVC |
| GUI 自动化 | Windows UI Automation（UIAutomation COM） |
| 托盘 UI | C# / .NET 8 / WinForms |
| VM 侧 MCP Server | Python 3 |
| VM 环境 | WSL2 (Debian) + OpenClaw |
| JSON | nlohmann/json |
| 错误处理 | tl::expected |
| 日志 | spdlog |
| 配置 | toml++ |
| 命令行 | cxxopts |

---

## 许可证

请参阅项目根目录的 LICENSE 文件。
