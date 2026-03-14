---
name: clawshell-gui
description: "Windows GUI automation via ClawShell MCP Server. Use when: (1) listing or inspecting visible windows on the Windows host, (2) clicking, double-clicking, or right-clicking UI elements, (3) typing text into input fields or sending keystrokes, (4) activating, focusing, minimizing, or dragging windows, (5) scrolling within controls, (6) reading UI control trees for accessibility inspection, (7) capturing system info or screen coordinates, (8) executing programs on the Windows host, (9) writing files on the host filesystem. NOT for: Linux/macOS GUI operations, web browser automation (use browser tooling), or tasks that don't involve the Windows desktop."
metadata:
  {
    "openclaw":
      {
        "emoji": "🖥️",
        "os": ["linux"],
        "requires": { "bins": ["python3"] },
      },
  }
---

# ClawShell GUI Skill

Control the Windows host desktop from inside the WSL2 VM via ClawShell's MCP tools.
All GUI operations are sent through AF_VSOCK to the ClawShell daemon running on the host,
which routes them to the `ax` capability plugin for execution.

## Setup

The ClawShell MCP Server must be registered in OpenClaw's acpx config.
Add to `~/.openclaw/openclaw.json`:

```json
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

The host-side ClawShell daemon must be running and the vsock server listening on port 100.

## Available Tools

### Task Lifecycle

- `gui.begin_task` — Start a new task session. Returns a `task_id` used for security tracking.
  Required params: `session_id`, `root_description`.
- `gui.end_task` — End the current task. Optional params: `task_id`, `status`.

Always call `gui.begin_task` before performing GUI operations, and `gui.end_task` when done.
The task context enables the host's security chain to audit and authorize operations.

### Window Discovery

- `gui.list_windows` — List all visible top-level windows. Use this first to discover available targets.
- `gui.get_ui_tree` — Get the accessibility control tree of a specific window.
  Required: `window_id`. Optional: `max_depth` (default 8), `include_bounds`.
- `gui.activate_window` — Bring a window to the foreground.
  Required: `window_id`.

### Interaction

- `gui.click` — Click a UI element by accessibility path. Required: `element_path`.
- `gui.set_value` — Set text in an input field. Required: `element_path`. Optional: `value`.

### Typical Workflow

```
1. gui.begin_task  → get task_id
2. gui.list_windows  → find target window
3. gui.get_ui_tree  → discover element paths
4. gui.click / gui.set_value  → interact
5. gui.end_task  → close session
```

## Notes

- Element paths come from `gui.get_ui_tree`. Always inspect the tree before clicking.
- The host security chain may prompt the user for confirmation on sensitive operations.
- All operations are synchronous — each call blocks until the host responds.
- Connection errors (vsock down, daemon not running) surface as JSON-RPC error responses.
