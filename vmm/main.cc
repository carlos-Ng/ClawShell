// main.cc — vmm.exe 入口点（占位）
//
// 未来每个 WSL2 distro 对应一个 vmm.exe 实例：
//   - Channel 1 Named Pipe 服务端（与 daemon 通信）
//   - Channel 3 vsock 客户端/服务端（与 VM 内 mcp_server.py 通信）
//   - Watchdog 监控 distro 健康状态

#include "common/log.h"

int main(int /*argc*/, char* /*argv*/[])
{
	LOG_INFO("vmm.exe placeholder — not yet implemented");
	return 0;
}
