# VMM Phase Progress — feat/vmm 分支

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

---

## 2. 待完成任务

| # | 文件 | 说明 |
|---|------|------|
| 5 | `mcp/` Python | 从 AI-agent-sec vm-side/mcp_server/ 复制，frame 协议改为 FrameCodec |

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

## 5. 下一步恢复工作时的入口

```
Task #5（mcp/ Python）
```

vm_manager.cc 和 CMakeLists.txt 均已完成。
附带修复：vsock_server.cc 中 sendExact/recvExact 提取为自由函数（解决编译错误）。
