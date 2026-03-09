#pragma once

#include "ipc/ipc_server.h"

#include <memory>

namespace clawshell {
namespace ipc {

// WindowsIpcServer 是基于 Windows Named Pipe 的 IpcServerInterface 实现。
// 对应 macOS 平台的 UnixIpcServer（Unix Domain Socket），由 CMakeLists.txt
// 按平台选择编译，共同实现 IpcServerInterface 抽象接口。
//
// 内部架构：
//   - 一个 Accept 线程：循环 ConnectNamedPipe，将已连接的管道 HANDLE 投入工作队列。
//   - N 个 Worker 线程（线程池）：从队列取出 HANDLE，处理该连接完整生命周期
//     （支持单连接内多次请求-响应），直至客户端主动断开。
//   - JSON-RPC 2.0 协议由 Worker 线程内联解析，无需外部协议服务器。
class WindowsIpcServer : public IpcServerInterface
{
public:
	WindowsIpcServer();
	~WindowsIpcServer() override;

	WindowsIpcServer(const WindowsIpcServer&)            = delete;
	WindowsIpcServer& operator=(const WindowsIpcServer&) = delete;

	void registerModule(std::string_view module_name, ModuleHandler handler) override;
	Status start(std::string_view pipe_path, int thread_pool_size = 8) override;
	void stop() override;

private:
	struct Implement;
	std::unique_ptr<Implement> implement_;
};

} // namespace ipc
} // namespace clawshell
