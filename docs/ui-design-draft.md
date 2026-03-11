# ClawShell UI 设计规范

> 状态: 进行中 (In Progress)
> 更新日期: 2026-03-11
> 目的: 定义 ClawShell WinForms UI 客户端的功能范围、Channel 2 协议规范与交互设计

---

## 一、目标与定位

**项目目标**：ClawShell 是为了延伸 OpenClaw 的能力到宿主机上，并且能够在安全可控的范围内对宿主机的资源进行操作。

**界面定位**：界面是用户与 ClawShell 之间的「控制面」，核心职责是：

1. **安全决策** — 在需要时让用户批准或拒绝 Agent 的操作
2. **可见性** — 让用户知道 Agent 在做什么、能做什么
3. **控制权** — 让用户配置和调整安全策略

---

## 二、实现现状

### 已完成（daemon 侧）

| 组件 | 状态 | 说明 |
|------|------|------|
| **UIService** | ✅ 完成 | Channel 2 Named Pipe 服务端，管理连接生命周期 |
| **Channel 2 协议** | ✅ 完成 | 双向 JSON + Length-prefix framing |
| **TaskRegistry** | ✅ 完成 | 任务生命周期管理 + 意图指纹授权缓存 |
| **op_log 推送** | ✅ 完成 | 每次能力调用后推送结构化操作日志 |
| **confirm 弹窗请求** | ✅ 完成 | NeedConfirm 时通过 Channel 2 发送确认请求 |
| **fingerprint 缓存** | ✅ 完成 | `trust_fingerprint=true` 时缓存，相同操作自动放行 |
| **task_begin/end 通知** | ✅ 完成 | 任务开始/结束时推送 |

### 待完成（UI 侧）

| 组件 | 状态 | 说明 |
|------|------|------|
| **WinForms UI 应用** | ⏳ 待实现 | Channel 2 客户端，系统托盘 + 主界面 |

---

## 三、Channel 2 协议规范

Channel 2 是 daemon 与 WinForms UI 之间的双向事件总线，使用 Windows Named Pipe。

### 3.1 传输层

- **Named Pipe 路径**：`\\.\pipe\crew-shell-service-ui`（可通过 `clawshell.toml` 的 `[ui] pipe_path` 配置）
- **帧格式**：4 字节大端 uint32 长度前缀 + UTF-8 JSON 正文
- **最大帧大小**：4 MiB
- **连接模式**：daemon 为服务端，UI 为客户端；UI 断线后 daemon 自动重新监听

### 3.2 消息类型（Daemon → UI）

#### `status` — 连接状态

UI 连接时 daemon 立即推送一次，此后状态变更时再次推送。

```json
{
  "type": "status",
  "agent_connected": true
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `agent_connected` | bool | Channel 1 是否有 Agent 连接 |

#### `task_begin` — 任务开始

```json
{
  "type": "task_begin",
  "task_id": "task-1",
  "root_description": "帮我把邮件里的附件保存到 Downloads 文件夹"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `task_id` | string | daemon 分配的唯一任务 ID |
| `root_description` | string | 用户原始意图（信任锚点，子任务继承） |

#### `task_end` — 任务结束

```json
{
  "type": "task_end",
  "task_id": "task-1"
}
```

#### `op_log` — 操作日志

```json
{
  "type":      "op_log",
  "task_id":   "task-1",
  "operation": "click",
  "result":    "confirmed",
  "source":    "user_confirm",
  "detail":    "capability_ax",
  "timestamp": 1741651234567
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `task_id` | string | 所属任务 ID |
| `operation` | string | 操作名，如 `click`、`set_value` |
| `result` | string | `allowed` / `confirmed` / `denied` |
| `source` | string | `auto_allow` / `fingerprint_cache` / `user_confirm` / `rule_deny` |
| `detail` | string | 能力模块名，如 `capability_ax` |
| `timestamp` | int64 | Unix 时间戳（毫秒） |

**result × source 组合含义**：

| result | source | 含义 |
|--------|--------|------|
| `allowed` | `auto_allow` | 安全策略直接放行 |
| `allowed` | `fingerprint_cache` | 意图指纹缓存命中，自动放行 |
| `confirmed` | `user_confirm` | 用户弹窗确认 |
| `denied` | `user_confirm` | 用户弹窗拒绝 |
| `denied` | `rule_deny` | 安全规则拒绝（含 preHook Deny 与 postHook Deny） |

#### `confirm` — 用户确认请求

当安全策略返回 `NeedConfirm` 且指纹缓存未命中时，daemon 发送此消息，等待 UI 响应。

```json
{
  "type":             "confirm",
  "id":               "conf-42",
  "task_id":          "task-1",
  "root_description": "帮我把邮件里的附件保存到 Downloads 文件夹",
  "capability":       "capability_ax",
  "operation":        "click",
  "params":           { "element_path": "/w3/toolbar/btn_delete" },
  "reason":           "GUI 点击操作需用户确认",
  "fingerprint":      "capability_ax|click"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | string | 请求唯一 ID，响应时须原样返回 |
| `task_id` | string | 所属任务 ID |
| `root_description` | string | 用户原始意图，供弹窗上下文展示 |
| `capability` | string | 能力模块名 |
| `operation` | string | 操作名 |
| `params` | object | 操作参数 |
| `reason` | string | 安全规则触发原因 |
| `fingerprint` | string | 意图指纹展示字符串，如 `capability_ax|click` |

### 3.3 消息类型（UI → Daemon）

#### `confirm_response` — 用户确认响应

UI 必须在收到 `confirm` 后返回此消息（在 daemon `timeout_secs` 内）。
超时未响应时，daemon 按 `timeout_mode` 配置自动处理（`timeout_deny` / `timeout_allow`）。

```json
{
  "type":              "confirm_response",
  "id":                "conf-42",
  "confirmed":         true,
  "trust_fingerprint": false
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | string | 对应 `confirm` 消息的 `id` |
| `confirmed` | bool | `true` = 允许，`false` = 拒绝 |
| `trust_fingerprint` | bool | `true` = 本任务内相同操作不再询问（写入指纹缓存） |

---

## 四、界面功能规范

### 4.1 系统托盘（必须）

- **常驻托盘图标**，表示 ClawShell UI 已就绪
- **图标状态**：区分「Channel 2 已连接」与「未连接」两种视觉状态
- **有需要确认时**：托盘图标闪烁或/并弹出系统通知，引导用户打开确认弹窗
- **右键菜单**：至少包含「显示主界面」和「退出」

### 4.2 确认弹窗（必须）

收到 `confirm` 消息时弹出，展示：

```
┌─────────────────────────────────────────────────────┐
│  ClawShell — 操作确认                                 │
│                                                      │
│  任务意图：帮我把邮件里的附件保存到 Downloads 文件夹     │
│                                                      │
│  操作：capability_ax / click                          │
│  原因：GUI 点击操作需用户确认                           │
│  参数：element_path = /w3/toolbar/btn_delete          │
│                                                      │
│  [✓] 本任务内相同操作不再询问                           │
│                                                      │
│  [允许]                    [拒绝]                     │
│                                                      │
│  倒计时：58 秒后自动拒绝                                │
└─────────────────────────────────────────────────────┘
```

- **「本任务内相同操作不再询问」**：复选框，选中则 `trust_fingerprint=true`
- **倒计时**：仅 `timeout_mode=timeout_deny` 或 `timeout_allow` 时显示；文案根据模式调整（「自动拒绝」/「自动允许」）
- **`wait_forever` 模式**：不显示倒计时，无限等待

### 4.3 主界面（推荐）

主界面包含以下区域：

#### 状态栏
- daemon Channel 2 连接状态（已连接 / 未连接）
- Agent Channel 1 连接状态（来自 `status.agent_connected`）

#### 任务列表
- 显示所有活跃任务：`task_id`、`root_description`、开始时间
- 任务结束后可保留一段时间供审阅

#### 操作日志
- 实时展示 `op_log` 消息流
- 每条记录展示：时间、任务、操作、结果（颜色区分 allowed / confirmed / denied）
- 支持按任务过滤

### 4.4 安全规则配置（可选）

- 可视化编辑 `security_filter_rules.toml` 的 `deny` / `confirm` 规则
- 或提供简化开关：「危险操作需要我确认」等高层开关

### 4.5 服务控制（可选）

- 展示 daemon 状态
- 可选：启动 / 停止 daemon 按钮

---

## 五、与 daemon 的差异对比（vs 原设计草稿）

| 维度 | 旧设计草稿 | 当前实现 |
|------|-----------|---------|
| 确认通道 | 独立 Named Pipe（`confirm_socket_path`） | Channel 2 UIService（统一双向事件总线） |
| 确认请求格式 | `{id, capability, operation, params, reason}` | 新增 `task_id`、`root_description`、`fingerprint` |
| `trust_fingerprint` | 无 | 有（用户可选，写入任务级指纹缓存） |
| 任务上下文 | 无 | 有（`task_id`、`root_description`、`task_begin/end`） |
| op_log | 无 | 有（结构化，含 result × source 语义） |
| 超时处理 | 无（直接拒绝） | 三种模式（`wait_forever` / `timeout_deny` / `timeout_allow`） |
| Python 工具 | `confirm_client.py` | 已移除（UIService 替代） |

---

## 六、配置参数

WinForms UI 需读取或感知以下配置（来自 `clawshell.toml`）：

```toml
[ui]
pipe_path    = "\\\\.\\pipe\\crew-shell-service-ui"
timeout_mode = "timeout_deny"   # wait_forever / timeout_deny / timeout_allow
timeout_secs = 60
```

UI 客户端连接时，daemon 会立即推送一条 `status` 消息作为握手。

---

## 七、现有工具

| 工具 | 用途 |
|------|------|
| `tools/ax_test_client.py` | Channel 1 AX 能力测试客户端 |
| `tools/mcp_server.py` | MCP Server，供 AI Agent 使用 |

> `tools/confirm_client.py` 已归档（对应的 DaemonConfirmHandler 已移除）。

---

## 八、待确认问题

1. **确认弹窗容错**：daemon 超时自动处理后 UI 仍响应 → UI 需要丢弃对应 `id` 的响应（daemon 已通过 `cancelAllPendingConfirms` 标记失效）？还是 daemon 静默忽略过期响应？
2. **多重确认并发**：多个 capability worker 同时触发 `NeedConfirm` 时（理论上存在），UI 需排队展示还是叠加弹窗？
3. **托盘形态**：是否希望托盘为主入口，主界面默认隐藏？
4. **技术栈**：WinForms（已有 `ui/` 目录基础代码）或迁移到 WPF？

---

## 九、参考

- `include/ipc/ui_service.h` — UIService 与 UIMessageFactory 完整接口
- `daemon-service/ipc/ui_service.cc` — UIService 实现（serviceLoop、askConfirm、帧格式）
- `config/clawshell.toml` — 完整配置示例
- `README.md` — IPC 通道与安全机制概述
