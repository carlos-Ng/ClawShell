# VMM Phase Progress

> 最后更新：2026-03-14
> 本文件用于网络中断后快速恢复上下文，不替代代码注释。

---

## 1. 已完成文件

| 文件 | 状态 | 说明 |
|------|------|------|
| `include/vmm/vm_manager.h` | ✅ 完成 | VMManagerInterface + DistroConfig + DistroState，全用 Status 返回值 |
| `include/vmm/vmm_channel.h` | ✅ 完成 | Channel 1 命名管道协议常量（消息 type 字符串、管道名生成函数） |
| `include/vmm/vsock_server.h` | ✅ 完成 | Channel 3 vsock 服务端抽象接口 |
| `vmm/ipc/vsock_server.cc` | ✅ 完成 | WindowsVsockServer（AF_HYPERV，HV_GUID_CHILDREN，FrameCodec 收发） |
| `vmm/ipc/hvsocket_defs.h` | ✅ 完成 | AF_HYPERV/SOCKADDR_HV/HV_GUID_CHILDREN/vsockPortToServiceId |
| `vmm/vm/wsl_com_interfaces.h` | ✅ 完成 | IWSLService/IWSLDistribution COM 声明，namespace clawshell::vmm |
| `vmm/vm/vm_manager.cc` | ✅ 完成 | WslVMManager 实现，Status 返回值 + LOG 全覆盖 + ClawShell 路径 |
| `include/common/status.h` | ✅ 补充 | 新增 ALREADY_EXISTS / NOT_FOUND 两个 Status::Code |
| `vmm/CMakeLists.txt` | ✅ 完成 | clawshell_vmm 静态库 + vmm.exe 占位，链接 Ole32/ws2_32/wslapi/shlwapi |
| `vmm/main.cc` | ✅ 完成 | vmm.exe 入口占位 |
| `mcp/server/vsock_client.py` | ✅ 完成 | VM 侧 AF_VSOCK 客户端，ClawShell FrameCodec 协议（4B 长度前缀 + JSON body） |
| `mcp/server/mcp_server.py` | ✅ 完成 | VM 侧 MCP Server 入口，stdio JSON-RPC → VsockClient → Host |
| `mcp/client/clawshell-gui/SKILL.md` | ✅ 完成 | OpenClaw skill 定义，指引 agent 使用 GUI tools |

---

## 2. 待完成任务

（暂无）

---

## 3. vm_manager.cc 实现要点

### 3.1 文件头与 include
```cpp
#include "vmm/vm_manager.h"
#include "vmm/vm/wsl_com_interfaces.h"
#include "common/log.h"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <objbase.h>
#include <wslapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#pragma comment(lib, "shlwapi.lib")
```

### 3.2 命名空间
```cpp
namespace clawshell { namespace vmm { ... } }
// 原来是 enclave::vm
```

### 3.3 返回值变更对照表

| 原方法（bool/wstring） | 新方法（Status） | 失败时的 Status |
|---|---|---|
| `createDistro` → bool | `Status createDistro(...)` | `ALREADY_EXISTS` / `IO_ERROR` / `INTERNAL_ERROR` |
| `startDistro` → bool | `Status startDistro(...)` | `NOT_FOUND` / `IO_ERROR` |
| `stopDistro` → bool | `Status stopDistro(...)` | `IO_ERROR` |
| `destroyDistro` → bool | `Status destroyDistro(...)` | `IO_ERROR` |
| `snapshotDistro` → wstring | `Status snapshotDistro(..., wstring& out_path)` | `IO_ERROR` |
| `restoreFromSnapshot` → bool | `Status restoreFromSnapshot(...)` | `IO_ERROR` |
| `lastCreateHr()` + `getLastWslDiagnostics()` | 合并为 `lastDiagnostics()` → string | - |

### 3.4 日志宏替换
- 无输出 → `LOG_INFO(...)` / `LOG_ERROR(...)` / `LOG_WARN(...)`
- 原代码无日志，均为新增

### 3.5 安装目录路径变更
- 原：`%LOCALAPPDATA%\agent-enclave\distros\<name>`
- 新：`%LOCALAPPDATA%\ClawShell\distros\<name>`

### 3.6 WslVMManager 私有成员
```cpp
IWSLService* com_service_       = nullptr;
bool         com_init_attempted_ = false;
bool         com_available_      = false;
HRESULT      last_hr_            = S_OK;  // 合并 last_create_hr_
std::string  last_diagnostics_;            // 合并 last_wsl_diagnostics_
```

---

## 4. 关键架构决策（已确认）

- **Channel 1**：Named Pipe `\\.\pipe\clawshell-vmm-{distro_name}`，vmm.exe ↔ daemon
- **Channel 2**：Named Pipe（现有 UI 通道，不动）
- **Channel 3**：AF_HYPERV vsock，VM 内 mcp_server.py → daemon（FrameCodec）
- **vsock 绑定**：`HV_GUID_CHILDREN`（接受所有子 VM，无需查具体 VM GUID）
- **协议统一**：全部用 ClawShell FrameCodec（4B 大端长度前缀 + UTF-8 JSON body）
- **vmm.exe**：Windows 宿主进程（非 VM 内部），每个 distro 一个实例，watchdog 监控

---

## 5. mcp/ Python 模块迁移要点

### 5.1 协议变更

| 项目 | 旧（AI-agent-sec） | 新（ClawShell） |
|------|---------------------|-----------------|
| 帧头 | magic(2B) + length(4B) + type(1B) + task_id(16B) | length(4B) |
| 帧头大小 | 23 字节 | 4 字节 |
| 操作路由 | FrameType 枚举（1B 二进制） | JSON body `{"type": "capability", "capability": "ax", "operation": "..."}` |
| 任务 ID | 帧头中 16 字节二进制 | JSON body `"task_id"` 字段（十六进制字符串） |
| 响应类型 | FrameType.RESP_SUCCESS / RESP_ERROR | `{"success": true/false}` |

### 5.2 便捷方法统一入口

所有 ax 插件操作统一通过 `call_capability("ax", operation, params)` 调用，
对应 Host 侧 Channel 1 的 `"capability"` 消息类型 → CapabilityService → ax 插件。

---

## 6. mcp/ 目录结构与 OpenClaw 集成

### 6.1 目录结构

```
mcp/
├── server/                          ← MCP Server（运行在 VM 内）
│   ├── vsock_client.py              ← AF_VSOCK 客户端（FrameCodec → Host daemon）
│   └── mcp_server.py               ← MCP Server 入口（stdio JSON-RPC）
│
└── client/                          ← OpenClaw 集成
    └── clawshell-gui/               ← OpenClaw skill
        └── SKILL.md                 ← skill 定义（agent 触发指南）
```

### 6.2 数据流

```
OpenClaw (VM)
  └─ acpx mcpServers: stdio 启动 mcp_server.py
       └─ VsockClient: AF_VSOCK (CID=2, Port=100)
            └─ Host daemon: FrameCodec → CapabilityService → ax 插件
```

### 6.3 OpenClaw 配置

```json
// ~/.openclaw/openclaw.json
{
  "plugins": {
    "acpx": {
      "mcpServers": {
        "clawshell-gui": {
          "command": "python3",
          "args": ["/path/to/clawshell/mcp/server/mcp_server.py"]
        }
      }
    }
  }
}
```

OpenClaw 的 acpx 扩展原生支持 stdio MCP Server，会自动发现 get_manifest 返回的 tools。
不需要单独写 MCP client——OpenClaw 自带。

---

## 7. 下一步

所有 VMM Phase 任务已完成。
