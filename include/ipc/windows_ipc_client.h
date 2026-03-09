#pragma once

#include "ipc/ipc_client.h"

#include <memory>

namespace clawshell {
namespace ipc {

// WindowsIpcClient 是基于 Windows Named Pipe 的 IpcClientInterface 实现。
// 对应 macOS 平台的 UnixIpcClient（Unix Domain Socket），由 CMakeLists.txt
// 按平台选择编译，共同实现 IpcClientInterface 抽象接口。
// 使用 Length-prefix 帧格式（[uint32 len][JSON body]）传输 JSON-RPC 2.0 消息。
class WindowsIpcClient : public IpcClientInterface
{
public:
	WindowsIpcClient();
	~WindowsIpcClient() override;

	WindowsIpcClient(const WindowsIpcClient&)            = delete;
	WindowsIpcClient& operator=(const WindowsIpcClient&) = delete;

	Status connect(std::string_view pipe_path) override;
	void disconnect() override;
	Result<nlohmann::json> call(std::string_view method,
	                            const nlohmann::json& params) override;

private:
	struct Implement;
	std::unique_ptr<Implement> implement_;
};

} // namespace ipc
} // namespace clawshell
