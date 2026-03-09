#pragma once

#include "common/error.h"

#include <nlohmann/json.hpp>
#include <string_view>

namespace clawshell {
namespace ipc {

// IpcClientInterface 定义本地 IPC 客户端的抽象接口。
//
// 职责：
// - 连接到本地 IPC 通道（Windows: Named Pipe；macOS: Unix Domain Socket）；
// - 以 JSON-RPC 2.0 格式发起同步调用并返回结果。
class IpcClientInterface
{
public:
	virtual ~IpcClientInterface() = default;

	// connect 连接到指定的本地 IPC 通道。
	//
	// 该方法具有幂等语义：若已处于连接状态，直接返回 Status::Ok()，不重复建立连接。
	//
	// 入参:
	// - pipe_path: 服务端监听的通道路径
	//              （Windows: \\.\pipe\<name>；macOS: Unix socket 文件路径）。
	//
	// 出参/返回:
	// - Status::Ok()：连接成功，或已处于连接状态。
	// - Status(IO_ERROR)：连接失败。
	virtual Status connect(std::string_view pipe_path) = 0;

	// disconnect 断开与服务端的连接并释放 socket 资源。
	virtual void disconnect() = 0;

	// call 发起一次同步 JSON-RPC 2.0 调用，阻塞直到收到响应。
	//
	// 入参:
	// - method: 方法名，格式为 "module.operation"，例如 "ax.list_windows"。
	// - params: 请求参数（JSON 对象），无参数时传 {} 空对象。
	//
	// 出参/返回:
	// - Result::Ok(json)：调用成功，json 为服务端 result 字段的值。
	// - Result::Error(status)：调用失败或服务端返回 error 响应。
	virtual Result<nlohmann::json> call(std::string_view method,
	                                    const nlohmann::json& params) = 0;
};

} // namespace ipc
} // namespace clawshell
