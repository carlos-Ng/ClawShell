# ClawShell

[English](README.md) | [简体中文](README.zh-CN.md)

ClawShell is a **host-side capability gateway** designed for **AI agents**. It uses virtualization to isolate the agent in a separate environment while extending carefully controlled host capabilities back to that agent, allowing it to operate on the real desktop under user authorization and review.

**Core idea**: the AI agent runs inside an isolated environment and accesses the host only through ClawShell's controlled window; every action is reviewed by the security gateway, and the user always keeps the final decision.

---

## Vision

The system consists of two isolated domains:

| Domain | Components | Responsibility |
|----|------|------|
| **Isolated environment** | AI Agent + MCP Client | The agent runs inside a virtualized environment and cannot access the host directly |
| **Host machine** | ClawShell daemon + capability plugins + WinForms UI | Receives agent requests and executes GUI operations after security review |

If the agent wants to do anything, it must go through ClawShell approval. The security gateway runs on the host independently from the agent, so even if the agent is compromised, an attacker can only issue "requests"; whether they are executed is decided solely by the host side.

**Capability extension**: ClawShell exposes host capabilities such as window enumeration, UI tree retrieval, clicking, input, scrolling, and key operations as MCP tools. This lets an agent running in an isolated environment operate on the real desktop while remaining fully observable and controllable.

---

## Features

- **Virtualized isolation** - The AI agent runs in an isolated environment and cannot directly access the host; all operations go through ClawShell approval
- **Capability extension** - Host GUI capabilities are safely exposed as MCP tools, including window enumeration, UI tree access, clicking, input, and more
- **Structured GUI descriptions** - UI Automation is serialized into compact AXT text so text-only models can understand the UI without screenshots
- **Security gateway** - Bidirectional review before and after execution; dangerous operations require user confirmation, and the user always has final control
- **Intent fingerprint cache** - If the user selects "do not ask again within this task", repeated operations of the same type are auto-approved to reduce duplicate prompts
- **Task lifecycle management** - Each agent session maps to a task, and authorization cache is cleared automatically when the task ends to prevent permission leakage across tasks
- **UI event bus** - The WinForms UI receives task status, operation logs, and confirmation requests in real time through Channel 2
- **C++ implementation** - The host daemon ships as a single binary with no Python runtime required
- **MCP protocol** - Compatible with MCP clients such as Claude Desktop, Cursor, and OpenClaw

---

## Quick Install

### System Requirements

| Requirement | Details |
|------|------|
| Windows 10 2004 (Build 19041) or later | Minimum requirement for WSL2 |
| WSL2 enabled | See instructions below |
| Disk space >= 4 GB | For rootfs and binaries |
| Memory >= 8 GB | For WSL2 and agent runtime |

If **WSL2 is not installed yet**, run the following in an elevated PowerShell:

```powershell
wsl --install --no-distribution
```

After installation, **restart the computer** before continuing.

### One-Command Install

Run this in **PowerShell** with normal user permissions:

```powershell
# Install the latest version
irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex

# Install a specific version
irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex -Version 0.1.0

# Or download the installer script for a fixed version directly
# The version is already encoded in the URL, so -Version is not needed
irm https://github.com/carlos-Ng/ClawShell/releases/download/v0.1.0/install.ps1 | iex
```

The installer automatically checks WSL2, downloads components, imports the VM image, configures the AI backend, generates a gateway token, enables auto-start, and launches ClawShell. At the end, the terminal prints the OpenClaw WebUI URL and token.

### Upgrade and Uninstall

```powershell
# Upgrade to the latest version while preserving data
irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex -Upgrade

# Uninstall
irm https://github.com/carlos-Ng/ClawShell/releases/latest/download/install.ps1 | iex -Uninstall
```

---

## First Run

1. **Confirm ClawShell is running**: check for the ClawShell tray icon, or launch `%LOCALAPPDATA%\ClawShell\bin\claw_shell_ui.exe` manually
2. **Open OpenClaw**: visit `http://localhost:18789` in a browser and enter the token shown during installation, or read it from `%LOCALAPPDATA%\ClawShell\gateway-token.txt`
3. **Integrate Claude Desktop**: add `clawshell` to `mcpServers` in `%APPDATA%\Claude\claude_desktop_config.json`, with `args` pointing to `%LOCALAPPDATA%\ClawShell\mcp\mcp_server.py`

---

## Architecture Overview

```
╔══════════════════════════════════════════════════════════════╗
║  Isolated Environment                                       ║
║  ┌────────────────────────────────────────────────────────┐  ║
║  │  AI Agent (OpenClaw / Claude Desktop / Cursor / etc.) │  ║
║  └────────────────────────────┬───────────────────────────┘  ║
║                               │ MCP (stdio)                  ║
║  ┌────────────────────────────▼───────────────────────────┐  ║
║  │  mcp_server.py - MCP bridge forwarding via AF_VSOCK   │  ║
║  └────────────────────────────┬───────────────────────────┘  ║
╚═══════════════════════════════╪══════════════════════════════╝
                                │ Channel 3 (AF_VSOCK)
╔═══════════════════════════════╪══════════════════════════════╗
║  Host Machine                 ▼                              ║
║  ┌────────────────────────────────────────────────────────┐  ║
║  │  claw_shell_service + VsockServer + claw_shell_vmm    │  ║
║  │  ├── TaskRegistry, SecurityChain, CapabilityService   │  ║
║  │  ├── capability_ax.dll, security_filter.dll          │  ║
║  │  └── UIService - Channel 2 event bus                  │  ║
║  └──────────────────────┬─────────────────────────────────┘  ║
║                         │ Channel 2 (Named Pipe)             ║
║                         ▼ status/task/op_log/confirm         ║
║  ┌─────────────────────────────────────────────────────────┐  ║
║  │  ClawShell UI (WinForms) - tray, task monitor, prompts │  ║
║  └─────────────────────────────────────────────────────────┘  ║
╚══════════════════════════════════════════════════════════════╝
```

> **Phase 1 compatibility**: the MCP Server can also run directly on the host and communicate with the daemon through a Named Pipe for local development, debugging, and integration with local MCP clients such as Claude Desktop.

---

## IPC Channels

ClawShell uses two independent Named Pipe channels:

### Channel 1: VM -> Daemon (Capability Invocation)

The main communication channel between the MCP Server and the daemon uses a typed message protocol:

| Message Type | Direction | Description |
|---------|------|------|
| `beginTask` | VM->Daemon | Starts an agent task and returns `task_id` |
| `endTask` | VM->Daemon | Ends the task (notification semantics, no response) |
| `capability` | VM->Daemon | Invokes a capability with `task_id`, operation name, and parameters |
| `capability_result` | Daemon->VM | Returns the result of a capability call, success or failure |

### Channel 2: Daemon <-> UI (Event Bus)

The bidirectional event bus between the daemon and the host WinForms UI:

| Message Type | Direction | Description |
|---------|------|------|
| `status` | Daemon->UI | Daemon connection status |
| `task_begin` | Daemon->UI | Task started notification |
| `task_end` | Daemon->UI | Task ended notification |
| `op_log` | Daemon->UI | Operation log (`allowed` / `confirmed` / `denied`) |
| `confirm` | Daemon->UI | Operation request that requires user confirmation |
| `confirm_response` | UI->Daemon | User response, including `trust_fingerprint` |

---

## Supported Operations

| Operation | Description |
|------|------|
| `list_windows` | Enumerate accessible top-level windows |
| `get_ui_tree` | Retrieve a window's UI element tree in AXT format |
| `click` / `double_click` / `right_click` | Click an element |
| `set_value` | Write text into an input box |
| `focus` | Move focus to an element |
| `scroll` | Scroll a scrollable region |
| `key_press` / `key_combo` | Send keystrokes and key combinations |
| `activate_window` | Bring a window to the foreground |

---

## Build

### Prerequisites

- Windows 10 or later
- CMake 3.20+
- Visual Studio 2022 (or Ninja + MSVC)
- A C++20 compiler

### Build Steps

```powershell
# Configure
cmake -S . -B build

# Build
cmake --build build

# Generate the dist directory (exe + dll + config)
cmake --build build --target dist

# Package the Release zip for GitHub Releases
cmake --build build --target release
# Output: clawshell-windows-<version>.zip (in the project root)
```

### Build Outputs

| Path | Description |
|------|------|
| `build\Debug\claw_shell_service.exe` | Main daemon |
| `build\Debug\claw_shell_vmm.exe` | VM manager |
| `build\daemon-service\Debug\capability_ax.dll` | AX capability module |
| `build\Debug\security_filter.dll` | Security filter module |
| `ui\bin\Release\net8.0-windows\win-x64\publish\claw_shell_ui.exe` | Tray UI |
| `dist\` | Distribution directory generated after `--target dist` |

---

## Run

### Option 1: Run from the `dist` directory (Recommended)

```powershell
cd dist
.\bin\claw_shell_service.exe -f -c config\clawshell.toml
```

`-f` means foreground mode and prints logs to the console.

### Option 2: Run from the project root (Development mode)

```powershell
.\build\Debug\claw_shell_service.exe -f
```

The top-level `clawshell.toml` points `module_dir` to `build\daemon-service`, which is convenient for development and debugging.

### Command-Line Arguments

| Argument | Description |
|------|------|
| `-c, --config <path>` | Configuration file path, default `clawshell.toml` |
| `-f, --foreground` | Run in foreground mode and print logs to the console |
| `--log-level <level>` | Log level: `trace`, `debug`, `info`, `warn`, `error` |
| `--socket <path>` | Override the Channel 1 pipe path |
| `--module-dir <path>` | Override the module DLL directory |

---

## Test Utilities

### Install Python Dependencies

```powershell
pip install -r tools\requirements.txt
```

### AX Test Client (Direct Channel 1 Access)

```powershell
# Start the daemon first, then run this in another terminal
python tools\ax_test_client.py

# Run a script in batch mode
python tools\ax_test_client.py -f tools\scripts\01_normal_task.txt
```

### MCP Server (for AI Agents)

```powershell
python tools\mcp_server.py
```

### Build the VM Rootfs

The rootfs contains the WSL2 VM image (Debian + OpenClaw + ClawShell MCP Server). Run this in Linux or WSL2:

```bash
bash scripts/build-rootfs.sh
```

This produces `clawshell-rootfs.tar.gz`, which can then be uploaded to GitHub Releases for `install.ps1` to download.

### Publish a Release

For each release, upload the following files to the GitHub Release page (tag format: `v<version>`):

| File | Source |
|------|------|
| `clawshell-windows-<ver>.zip` | Generated by `cmake --build build --target release` |
| `clawshell-rootfs.tar.gz` | Generated by `bash scripts/build-rootfs.sh` |
| `install.ps1` | `scripts/install.ps1` |

---

## Claude Desktop Integration

Add the following to `%APPDATA%\Claude\claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "clawshell": {
      "command": "python",
      "args": ["C:\\path\\to\\ClawShell\\tools\\mcp_server.py"]
    }
  }
}
```

Replace `C:\path\to\ClawShell` with the actual project path.

---

## Security Model

### Security Review Chain

Each capability invocation passes through the security module's `preHook` (inbound review) and `postHook` (outbound filtering) in sequence:

```
Request arrives
  │
  ▼ preHook (before execution)
  │  Deny        -> Reject, do not execute, push op_log(denied/rule_deny)
  │  NeedConfirm -> Check intent fingerprint cache
  │                └─ Hit      -> Allow directly, push op_log(allowed/fingerprint_cache)
  │                └─ Miss     -> Show confirmation dialog in UI
  │                               └─ Reject  -> Push op_log(denied/user_confirm)
  │                               └─ Confirm -> Optionally cache fingerprint, push op_log(confirmed/user_confirm)
  │  Pass        -> Continue
  │
  ▼ Capability execution
  │
  ▼ postHook (after execution)
  │  May redact sensitive return values
  │
  ▼ Return result, push op_log(allowed/auto_allow)
```

**Decision merging**: multiple security modules run by priority, and the strictest verdict wins (`Deny > NeedConfirm > Pass > Skip`).

### Intent Fingerprint Cache

If the user checks "do not ask again for the same operation within this task" in the confirmation dialog, the framework caches an intent fingerprint for that operation type (`capability + operation`). When the same operation is triggered again within the same task, it is allowed directly without another prompt. The cache is cleared automatically when the task ends so authorization does not leak across tasks.

### Rule Configuration

Security rules are configured in `config/security_filter_rules.toml`:

```toml
# Deny rule
[[deny]]
capability = "capability_ax"
operations = ["key_combo"]
params_field = "keys"
params_patterns = ["Win", "Cmd"]
reason = "Win/Cmd combinations can trigger system-level operations and are blocked"

# Confirmation rule
[[confirm]]
capability = "capability_ax"
operations = ["click", "double_click", "right_click"]
reason = "GUI click operations require user confirmation"
```

---

## Configuration

### Main Config (`clawshell.toml`)

```toml
[daemon]
socket_path      = "\\\\.\\pipe\\crew-shell-service"  # Channel 1 pipe
thread_pool_size = 4
log_level        = "debug"
module_dir       = "lib"                              # DLL directory (relative to dist)

[ui]
pipe_path    = "\\\\.\\pipe\\crew-shell-service-ui"   # Channel 2 pipe
timeout_mode = "timeout_deny"   # wait_forever / timeout_deny / timeout_allow
timeout_secs = 60               # user response timeout in seconds; ignored when wait_forever

[[modules]]
name = "capability_ax"

[[modules]]
name       = "security_filter"
priority   = 10
rules_file = "config\\security_filter_rules.toml"
```

### `timeout_mode` Explained

| Value | Behavior |
|----|------|
| `timeout_deny` | Automatically deny on timeout (default, security first) |
| `timeout_allow` | Automatically allow on timeout (app first) |
| `wait_forever` | Wait indefinitely for user input |

### Path Notes

- **Running from `dist`**: use `module_dir = "lib"` and a relative `config\` path for `rules_file`
- **Running from the project root**: use the top-level `clawshell.toml`, where `module_dir = "build\\daemon-service"`

---

## Project Structure

```
ClawShell/
├── include/                    # Public headers
├── daemon-service/             # C++ daemon implementation
├── vmm/                        # VM manager (claw_shell_vmm.exe)
├── ui/                         # ClawShell WinForms UI (C# .NET 8)
├── mcp/                        # MCP server implementation
├── config/                     # Configuration templates
├── scripts/                    # build-rootfs.sh, install.ps1
├── tools/                      # Development and testing tools (Python)
├── tests/                      # Unit tests
├── third_party/                # Third-party header-only libraries
└── clawshell.toml              # Root config for development
```

---

## Tech Stack

| Component | Choice |
|------|------|
| Language | C++20 |
| Build | CMake |
| JSON | nlohmann/json |
| Error handling | tl::expected |
| Logging | spdlog |
| Config | toml++ |
| CLI | cxxopts |
| GUI API | Windows UI Automation |

---

## License

This project is released under the [MIT License](LICENSE).

- **Commercial use**: Allowed
- **Modification and distribution**: Allowed, with copyright notice and full license text retained
- **Patent and liability**: Provided without warranty; see [LICENSE](LICENSE) for details

Copyright (c) 2025 [carlos-Ng](https://github.com/carlos-Ng)
