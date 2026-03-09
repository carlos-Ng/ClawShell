#pragma once

#include "common/status_converter.h"

#include <nlohmann/json.hpp>

namespace clawshell {
namespace ipc {

// JsonRpcStatusConverter 将 Status 转换为 JSON-RPC 2.0 error 对象（仅供 ipc 模块内部使用）。
//
// 错误码映射规则：
//   INVALID_ARGUMENT                          → -32602  Invalid params（参数非法）
//   CAPABILITY_NOT_FOUND, ELEMENT_NOT_FOUND,
//   WINDOW_NOT_FOUND                          → -32601  Method not found（目标不存在）
//   OPERATION_DENIED, CONFIRM_DENIED          → -32001  应用自定义：安全策略拒绝
//   CONFIRM_REQUIRED, CONFIRM_TIMEOUT         → -32002  应用自定义：需要用户确认（Phase 1 占位）
//   其他所有错误                               → -32603  Internal error
class JsonRpcStatusConverter : public StatusConverterInterface<nlohmann::json>
{
public:
	// convert 将 Status 转换为 JSON-RPC 2.0 error 对象。
	//
	// 入参:
	// - status: 待转换的 Status。
	//
	// 出参/返回:
	// - nlohmann::json: {"code": N, "message": "..."} 格式的 JSON 对象。
	nlohmann::json convert(const Status& status) const override;
};

} // namespace ipc
} // namespace clawshell
