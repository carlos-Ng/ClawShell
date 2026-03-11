#include "json_rpc_status_converter.h"

namespace clawshell {
namespace ipc {

// JSON-RPC 2.0 标准错误码
static constexpr int JSONRPC_METHOD_NOT_FOUND = -32601;
static constexpr int JSONRPC_INVALID_PARAMS   = -32602;
static constexpr int JSONRPC_INTERNAL_ERROR   = -32603;

// 应用自定义错误码（-32000 ~ -32099 由服务端保留使用）
static constexpr int JSONRPC_APP_OPERATION_DENIED = -32001;
static constexpr int JSONRPC_APP_CONFIRM_REQUIRED = -32002;

// convert 将 Status 转换为 JSON-RPC 2.0 error 对象。
nlohmann::json JsonRpcStatusConverter::convert(const Status& status) const
{
	int code;
	switch (status.code) {
	case Status::INVALID_ARGUMENT:
		code = JSONRPC_INVALID_PARAMS;
		break;
	case Status::CAPABILITY_NOT_FOUND:
	case Status::ELEMENT_NOT_FOUND:
	case Status::WINDOW_NOT_FOUND:
		code = JSONRPC_METHOD_NOT_FOUND;
		break;
	case Status::OPERATION_DENIED:
	case Status::CONFIRM_DENIED:
		code = JSONRPC_APP_OPERATION_DENIED;
		break;
	case Status::CONFIRM_REQUIRED:
	case Status::CONFIRM_TIMEOUT:
		code = JSONRPC_APP_CONFIRM_REQUIRED;
		break;
	default:
		code = JSONRPC_INTERNAL_ERROR;
		break;
	}
	const char* msg = (status.message != nullptr && status.message[0] != '\0')
	                      ? status.message
	                      : statusMessage(status.code);
	return nlohmann::json{{"code", code}, {"message", msg}};
}

} // namespace ipc
} // namespace clawshell
