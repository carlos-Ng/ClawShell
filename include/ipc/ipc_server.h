#pragma once

#include "common/error.h"

#include <nlohmann/json.hpp>
#include <functional>
#include <string>
#include <string_view>

namespace clawshell {
namespace ipc {

// ModuleHandler 是模块请求处理函数类型。
// 接收 operation（操作名）和 params（JSON 参数对象），返回 Result<json>。
using ModuleHandler = std::function<Result<nlohmann::json>(
	const std::string& operation,
	const nlohmann::json& params)>;

// IpcServerInterface 定义本地 IPC 服务端的抽象接口。
//
// 职责：
// - 管理本地 IPC 通道监听与线程池
//   （Windows: Named Pipe；macOS: Unix Domain Socket）；
// - 解析 JSON-RPC 2.0 协议帧；
// - 将 "module.operation" 格式的请求路由到对应的 ModuleHandler。
//
// 调用约定：registerModule 须在 start 之前完成。
class IpcServerInterface
{
public:
	virtual ~IpcServerInterface() = default;

	// registerModule 注册一个模块的请求处理器。
	//
	// 入参:
	// - module_name: 模块标识，例如 "ax"，对应 JSON-RPC method 前缀。
	// - handler: 模块处理函数，接收 operation 和 params，返回 Result<json>。
	virtual void registerModule(std::string_view module_name, ModuleHandler handler) = 0;

	// start 启动服务端，绑定并监听指定的本地 IPC 通道。
	//
	// 入参:
	// - pipe_path: 通道路径
	//              （Windows: \\.\pipe\<name>；macOS: Unix socket 文件路径）。
	// - thread_pool_size: 工作线程数量，默认 8。
	//
	// 出参/返回:
	// - Status::Ok()：启动成功。
	// - Status(IO_ERROR)：绑定或监听失败。
	virtual Status start(std::string_view pipe_path, int thread_pool_size = 8) = 0;

	// stop 优雅停止服务端，等待所有工作线程安全退出。
	virtual void stop() = 0;
};

} // namespace ipc
} // namespace clawshell
