#include "ipc/windows_ipc_client.h"
#include "frame.h"

#include <nlohmann/json.hpp>

#include <atomic>
#include <mutex>
#include <string>

#include <windows.h>

namespace clawshell {
namespace ipc {

// ─── Implement ──────────────────────────────────────────────────────────────

struct WindowsIpcClient::Implement
{
	HANDLE           pipe_ = INVALID_HANDLE_VALUE;
	std::mutex       call_mutex_;
	std::atomic<int> next_id_{1};

	// mapJsonRpcCodeToStatus 将 JSON-RPC 错误码反向映射为 Status::Code。
	//
	// 入参:
	// - json_rpc_code: JSON-RPC 错误码整数值。
	//
	// 出参/返回:
	// - 对应的 Status::Code 枚举值。
	static Status::Code mapJsonRpcCodeToStatus(int json_rpc_code);

	// parseResponse 解析 JSON-RPC 2.0 响应字符串为 Result<json>。
	//
	// 入参:
	// - response_str: 服务端返回的原始 JSON 字符串。
	//
	// 出参/返回:
	// - Result::Ok(json)：成功，值为 result 字段。
	// - Result::Error(status)：失败，status 对应 error 字段中的错误码。
	static Result<nlohmann::json> parseResponse(const std::string& response_str);
};

// ─── Implement 方法实现 ──────────────────────────────────────────────────────

// mapJsonRpcCodeToStatus 将 JSON-RPC 错误码反向映射为 Status::Code。
Status::Code WindowsIpcClient::Implement::mapJsonRpcCodeToStatus(int json_rpc_code)
{
	switch (json_rpc_code) {
	case -32602: return Status::INVALID_ARGUMENT;
	case -32601: return Status::CAPABILITY_NOT_FOUND;
	case -32001: return Status::OPERATION_DENIED;
	case -32002: return Status::CONFIRM_REQUIRED;
	default:     return Status::INTERNAL_ERROR;
	}
}

// parseResponse 解析 JSON-RPC 2.0 响应字符串。
Result<nlohmann::json> WindowsIpcClient::Implement::parseResponse(const std::string& response_str)
{
	try {
		auto resp = nlohmann::json::parse(response_str);
		if (resp.contains("error") && resp["error"].is_object()) {
			int code = resp["error"].value("code", static_cast<int>(-32603));
			return Result<nlohmann::json>::Error(mapJsonRpcCodeToStatus(code));
		}
		if (resp.contains("result")) {
			return Result<nlohmann::json>::Ok(resp["result"]);
		}
		return Result<nlohmann::json>::Error(Status::INTERNAL_ERROR,
		                                     "invalid response: missing result or error");
	} catch (const nlohmann::json::parse_error&) {
		return Result<nlohmann::json>::Error(Status::IO_ERROR, "invalid JSON response");
	} catch (const std::exception&) {
		return Result<nlohmann::json>::Error(Status::INTERNAL_ERROR, "invalid response");
	}
}

// ─── WindowsIpcClient 公开接口 ───────────────────────────────────────────────

WindowsIpcClient::WindowsIpcClient()
	: implement_(std::make_unique<Implement>())
{
}

WindowsIpcClient::~WindowsIpcClient()
{
	disconnect();
}

// connect 连接到指定的 Named Pipe。
Status WindowsIpcClient::connect(std::string_view pipe_path)
{
	if (implement_->pipe_ != INVALID_HANDLE_VALUE) {
		return Status::Ok();
	}

	std::string path(pipe_path);

	// 等待管道可用（服务端可能尚未启动）
	while (true) {
		implement_->pipe_ = ::CreateFileA(
		    path.c_str(),
		    GENERIC_READ | GENERIC_WRITE,
		    0,
		    nullptr,
		    OPEN_EXISTING,
		    0,
		    nullptr);
		if (implement_->pipe_ != INVALID_HANDLE_VALUE) {
			break;
		}
		DWORD err = ::GetLastError();
		if (err != ERROR_PIPE_BUSY) {
			return Status(Status::IO_ERROR, "failed to connect to named pipe");
		}
		// 管道忙，等待最多 1 秒后重试
		if (!::WaitNamedPipeA(path.c_str(), 1000)) {
			return Status(Status::IO_ERROR, "named pipe wait timeout");
		}
	}

	// 设置管道为字节读取模式
	DWORD mode = PIPE_READMODE_BYTE;
	if (!::SetNamedPipeHandleState(implement_->pipe_, &mode, nullptr, nullptr)) {
		::CloseHandle(implement_->pipe_);
		implement_->pipe_ = INVALID_HANDLE_VALUE;
		return Status(Status::IO_ERROR, "failed to set pipe mode");
	}
	return Status::Ok();
}

// disconnect 关闭管道连接并释放资源。
void WindowsIpcClient::disconnect()
{
	if (implement_->pipe_ != INVALID_HANDLE_VALUE) {
		::CloseHandle(implement_->pipe_);
		implement_->pipe_ = INVALID_HANDLE_VALUE;
	}
}

// call 发起一次同步 JSON-RPC 2.0 调用。
Result<nlohmann::json> WindowsIpcClient::call(std::string_view method,
                                              const nlohmann::json& params)
{
	int id = implement_->next_id_.fetch_add(1, std::memory_order_relaxed);
	nlohmann::json request = {
		{"jsonrpc", "2.0"},
		{"id",      id},
		{"method",  std::string(method)},
		{"params",  params}
	};
	// pipe_ 的检查与后续 I/O 必须在同一把锁内完成，避免 disconnect() 在检查后、
	// I/O 前关闭管道导致的 TOCTOU 竞态
	std::lock_guard<std::mutex> lock(implement_->call_mutex_);
	if (implement_->pipe_ == INVALID_HANDLE_VALUE) {
		return Result<nlohmann::json>::Error(Status::NOT_INITIALIZED, "not connected");
	}
	auto write_status = FrameCodec::writeFrame(implement_->pipe_, request.dump());
	if (!write_status.ok()) {
		return Result<nlohmann::json>::Error(write_status.code);
	}
	auto read_result = FrameCodec::readFrame(implement_->pipe_);
	if (read_result.failure()) {
		return Result<nlohmann::json>::Error(read_result.error());
	}
	return Implement::parseResponse(read_result.value());
}

} // namespace ipc
} // namespace clawshell
