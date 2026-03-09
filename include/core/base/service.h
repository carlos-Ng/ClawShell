#pragma once

#include "core/base/confirm.h"
#include "core/base/core_config.h"
#include "common/error.h"

#include <nlohmann/json.hpp>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace clawshell {
namespace core {

// CapabilityService 是 core 对外暴露的唯一入口，daemon 通过它访问所有能力。
//
// 职责：
// - 生命周期管理：init 时内部启动 ModuleManager，动态加载所有能力插件与安全模块；
//                 release 时逆序 Shutdown 所有模块。
// - 统一调用入口：callCapability 将请求透明地经过 SecurityChain 审查后，
//                 路由到对应的 CapabilityInterface 执行。
// - 确认通道管理：SecurityAction::NeedConfirm 时的用户确认流程由内部处理，
//                 daemon 不感知此细节。
//
// 使用示例：
//   CapabilityService service;
//   service.init(core_config);
//   for (const auto& name : service.capabilityNames()) {
//       ipc_server.registerModule(name, handler);
//   }
//   auto result = service.callCapability("capability_ax", "list_windows", {});
//   service.release();
class CapabilityService
{
public:
	CapabilityService();
	~CapabilityService();

	CapabilityService(const CapabilityService&)            = delete;
	CapabilityService& operator=(const CapabilityService&) = delete;

	// init 初始化 core 运行时。
	//
	// 内部流程：
	//   1. 遍历 config.modules，通过 ModuleManager 动态加载（dlopen/dlsym）各模块。
	//   2. 调用各模块的 init(spec.params) 完成初始化。
	//   3. 按 spec.priority 将安全模块注册进 SecurityChain。
	//
	// 入参:
	// - config: 由 daemon 解析 TOML 后构造的 CoreConfig，包含 module_dir 与模块列表。
	//
	// 出参/返回:
	// - Result::Ok()：初始化成功。
	// - Result::Error(status)：初始化失败，status 描述原因（模块加载失败等）。
	Result<void> init(const CoreConfig& config);

	// release 关闭 core 运行时，逆序 Shutdown 所有模块。
	//
	// 调用后 CapabilityService 不可再使用，再次使用前须重新调用 init。
	void release();

	// setConfirmHandler 注入用户确认通道实现。
	//
	// 须在 init 之前或之后调用均可；未注入时 NeedConfirm 直接返回 CONFIRM_REQUIRED 错误。
	// handler 的生命周期须长于 CapabilityService 实例。
	//
	// 入参:
	// - handler: 确认通道实现，不可为 nullptr（如需清除请传专门的 NullConfirmHandler）。
	void setConfirmHandler(ConfirmHandlerInterface* handler);

	// capabilityNames 返回已加载的所有能力模块名称列表。
	//
	// 须在 init 成功后调用。daemon 使用此列表向 IpcServer 注册 ModuleHandler，
	// 使 IPC 路由与 CapabilityService 中的能力模块保持一致。
	//
	// 出参/返回:
	// - 已加载能力模块的名称列表（与 ModuleInterface::name() 返回值一致）。
	std::vector<std::string> capabilityNames() const;

	// callCapability 是 daemon 调用能力的统一入口。
	//
	// 内部流程：
	//   1. 构造 SecurityContext（含 capability_name、operation、params）。
	//   2. SecurityChain::runPreHook —— 入站审查。
	//      - Deny        → 返回 Error(OPERATION_DENIED)。
	//      - NeedConfirm → Phase 1 暂返回 Error(CONFIRM_REQUIRED)。
	//      - Pass        → 继续。
	//   3. ModuleManager 根据 capability_name 路由到对应 CapabilityInterface。
	//   4. CapabilityInterface::execute(operation, params)。
	//   5. SecurityChain::runPostHook —— 出站过滤（含脱敏）。
	//   6. 返回处理后的结果。
	//
	// 入参:
	// - capability_name: 目标能力标识，例如 "capability_ax"。
	// - operation:       操作名称，例如 "list_windows"。
	// - params:          操作参数（JSON 对象），无参数时传空对象 {}。
	//
	// 出参/返回:
	// - Result::Ok(json)：操作成功，json 为返回数据。
	// - Result::Error(status)：操作失败或被拒绝，status.code 指明原因。
	Result<nlohmann::json> callCapability(std::string_view capability_name,
	                                      std::string_view operation,
	                                      const nlohmann::json& params);

private:
	struct Implement;
	std::unique_ptr<Implement> implement_;
};

} // namespace core
} // namespace clawshell
