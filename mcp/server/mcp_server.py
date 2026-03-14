#!/usr/bin/env python3
"""
mcp_server.py -- 最小 vGUI MCP Server（运行在 VM 内）

通过 stdin/stdout 提供 JSON-RPC 2.0 接口，暴露 GUI 操作工具。
所有 GUI 操作通过 AF_VSOCK + ClawShell FrameCodec 发送到宿主机 daemon，
由 CapabilityService 路由到具体插件（如 ax）执行。

支持的 JSON-RPC 方法：
  - get_manifest: 返回工具清单
  - call_tool:    调用指定工具

请求/响应格式（一行一个 JSON，JSON-RPC 2.0 子集）：

  Request:
    {"jsonrpc":"2.0","id":1,"method":"get_manifest","params":{}}
    {"jsonrpc":"2.0","id":2,"method":"call_tool",
     "params":{"tool":"gui.list_windows","arguments":{}}}

  Response:
    {"jsonrpc":"2.0","id":1,"result":{...}}
    {"jsonrpc":"2.0","id":2,"error":{"code":123,"message":"..."}}
"""

from __future__ import annotations

import json
import sys
import traceback
from dataclasses import dataclass
from typing import Any, Dict

from vsock_client import VsockClient, VsockError

JSON = Dict[str, Any]


@dataclass
class RpcRequest:
    id: Any
    method: str
    params: JSON


def _read_requests() -> JSON:
    """从 stdin 逐行读取 JSON-RPC 请求。"""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            _write_error(None, -32700, f"JSON 解析失败: {exc}")
            continue

        if not isinstance(obj, dict):
            _write_error(None, -32600, "无效请求: 根对象必须是 JSON 对象")
            continue

        yield obj


def _write_response(resp: JSON) -> None:
    """将响应写到 stdout（一行一个 JSON）。"""
    sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _write_error(_id: Any, code: int, message: str, data: JSON | None = None) -> None:
    err: JSON = {"code": code, "message": message}
    if data is not None:
        err["data"] = data
    _write_response({"jsonrpc": "2.0", "id": _id, "error": err})


# ── 工具清单 ─────────────────────────────────────────────────────────────

def _build_manifest() -> JSON:
    """返回静态工具清单。"""
    return {
        "tools": [
            {
                "name": "gui.list_windows",
                "description": "列出当前可见的顶层窗口列表。",
                "input_schema": {
                    "type": "object",
                    "properties": {},
                    "required": [],
                },
            },
            {
                "name": "gui.begin_task",
                "description": "开始一个新的 vGUI 任务，会返回 task_id。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "session_id": {"type": "string"},
                        "root_description": {"type": "string"},
                    },
                    "required": ["session_id", "root_description"],
                },
            },
            {
                "name": "gui.end_task",
                "description": "结束当前 vGUI 任务。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "task_id": {"type": "string"},
                        "status": {"type": "string"},
                    },
                    "required": [],
                },
            },
            {
                "name": "gui.click",
                "description": "在指定元素路径上执行一次点击。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "element_path": {"type": "string"},
                    },
                    "required": ["element_path"],
                },
            },
            {
                "name": "gui.get_ui_tree",
                "description": "获取指定窗口的 UI 控件树。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "window_id": {"type": "string"},
                        "max_depth": {"type": "integer"},
                        "include_bounds": {"type": "boolean"},
                    },
                    "required": ["window_id"],
                },
            },
            {
                "name": "gui.set_value",
                "description": "向指定路径的输入控件设置文本值。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "element_path": {"type": "string"},
                        "value": {"type": "string"},
                    },
                    "required": ["element_path"],
                },
            },
            {
                "name": "gui.activate_window",
                "description": "将指定窗口置于前台并激活。",
                "input_schema": {
                    "type": "object",
                    "properties": {
                        "window_id": {"type": "string"},
                    },
                    "required": ["window_id"],
                },
            },
        ],
    }


# ── McpServer ────────────────────────────────────────────────────────────

class McpServer:
    """MCP Server 封装，复用单个 VsockClient 连接。"""

    def __init__(self) -> None:
        self._client = VsockClient()
        self._connected = False

    def _ensure_connected(self) -> None:
        if not self._connected or not self._client.is_connected():
            self._client.connect()
            self._connected = True

    # ── RPC entrypoints ──────────────────────────────────────────────────

    def handle_get_manifest(self, req: RpcRequest) -> JSON:
        return _build_manifest()

    def handle_call_tool(self, req: RpcRequest) -> JSON:
        params = req.params or {}
        tool = params.get("tool")
        args = params.get("arguments") or {}

        if not isinstance(tool, str):
            raise ValueError("params.tool 必须是字符串")
        if not isinstance(args, dict):
            raise ValueError("params.arguments 必须是对象")

        self._ensure_connected()

        if tool == "gui.list_windows":
            result = self._client.list_windows()
        elif tool == "gui.begin_task":
            session_id = str(args.get("session_id", "session-unknown"))
            root_desc = str(args.get("root_description", ""))
            task_id = self._client.begin_task(
                session_id=session_id, root_description=root_desc
            )
            result = {"task_id": task_id}
        elif tool == "gui.end_task":
            task_id_hex = args.get("task_id", "")
            status = str(args.get("status", "success"))
            if task_id_hex:
                self._client._task_id = task_id_hex
            self._client.end_task(status=status)
            result = {"status": status, "ended": True}
        elif tool == "gui.click":
            element_path = args.get("element_path")
            if not isinstance(element_path, str) or not element_path:
                raise ValueError("gui.click 需要非空字符串参数 element_path")
            result = self._client.click(element_path)
        elif tool == "gui.get_ui_tree":
            window_id = args.get("window_id")
            if not isinstance(window_id, str) or not window_id:
                raise ValueError("gui.get_ui_tree 需要非空字符串参数 window_id")
            result = self._client.get_ui_tree(
                window_id=window_id,
                max_depth=int(args.get("max_depth", 8)),
                include_bounds=bool(args.get("include_bounds", False)),
            )
        elif tool == "gui.set_value":
            element_path = args.get("element_path")
            value = args.get("value", "")
            if not isinstance(element_path, str) or not element_path:
                raise ValueError("gui.set_value 需要非空字符串参数 element_path")
            result = self._client.set_value(element_path, str(value))
        elif tool == "gui.activate_window":
            window_id = args.get("window_id")
            if not isinstance(window_id, str) or not window_id:
                raise ValueError("gui.activate_window 需要非空字符串参数 window_id")
            result = self._client.activate_window(window_id)
        else:
            raise ValueError(f"未知工具: {tool}")

        return result


# ── 请求调度 ─────────────────────────────────────────────────────────────

def _dispatch(server: McpServer, obj: JSON) -> None:
    """单次请求调度。"""
    _id = obj.get("id")
    method = obj.get("method")
    params = obj.get("params") or {}

    if not isinstance(method, str):
        _write_error(_id, -32600, "无效请求: method 必须是字符串")
        return

    req = RpcRequest(id=_id, method=method, params=params)

    try:
        if method == "get_manifest":
            result = server.handle_get_manifest(req)
        elif method == "call_tool":
            result = server.handle_call_tool(req)
        else:
            _write_error(_id, -32601, f"未知方法: {method}")
            return
        _write_response({"jsonrpc": "2.0", "id": _id, "result": result})
    except VsockError as exc:
        _write_error(_id, 1001, f"Vsock 错误: {exc}")
    except Exception as exc:  # noqa: BLE001
        tb = traceback.format_exc()
        _write_error(
            _id,
            1000,
            f"服务器内部错误: {exc}",
            data={"traceback": tb},
        )


def main() -> int:
    server = McpServer()
    for obj in _read_requests():
        _dispatch(server, obj)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
