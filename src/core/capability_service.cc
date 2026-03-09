#include "core/base/service.h"
#include "core/base/capability.h"
#include "core/base/confirm.h"
#include "core/base/module_manager.h"
#include "core/base/security.h"

#include <atomic>
#include <memory>
#include <string>
#include <vector>

namespace clawshell {
namespace core {

// ─── Implement ──────────────────────────────────────────────────────────────

struct CapabilityService::Implement
{
	ModuleManager             manager_;
	SecurityChain             chain_;
	ConfirmHandlerInterface*  confirm_handler_ = nullptr;
	bool                      initialized_     = false;
};

// ─── CapabilityService 公开接口 ──────────────────────────────────────────────

CapabilityService::CapabilityService()
	: implement_(std::make_unique<Implement>())
{
}

CapabilityService::~CapabilityService()
{
	release();
}

// init 初始化 core 运行时：通过 ModuleManager 动态加载所有模块。
Result<void> CapabilityService::init(const CoreConfig& config)
{
	if (implement_->initialized_) {
		return Result<void>::Error(Status::INTERNAL_ERROR, "already initialized");
	}
	auto result = implement_->manager_.init(config, implement_->chain_);
	if (result.failure()) {
		return result;
	}
	implement_->initialized_ = true;
	return Result<void>::Ok();
}

// release 关闭 core 运行时，逆序释放所有已加载模块。
void CapabilityService::release()
{
	if (!implement_->initialized_) {
		return;
	}
	implement_->manager_.release();
	implement_->initialized_ = false;
}

// setConfirmHandler 注入用户确认通道实现。
void CapabilityService::setConfirmHandler(ConfirmHandlerInterface* handler)
{
	implement_->confirm_handler_ = handler;
}

// capabilityNames 返回已加载的所有能力模块名称列表。
std::vector<std::string> CapabilityService::capabilityNames() const
{
	return implement_->manager_.capabilityNames();
}

// callCapability 统一能力调用入口，经过 SecurityChain 审查后路由到对应插件。
//
// reason 透传机制：
//   Status 现在内部持有 std::string message_storage_，可直接以 std::move(reason)
//   构造 Status，无需 thread_local 缓冲区。Status 的拷贝/移动语义保证 message 指针
//   始终指向本对象内部存储，不受 Result 传递链影响。
//
// operation_id：
//   使用线程安全的全局计数器为每次调用分配会话内唯一 ID，供跨模块 trace 与审计。
//
// TODO: Phase 2 — 根据 operation 前缀（list_/get_ 等）推导 is_readonly，
//                 当前写死为 false，安全模块暂无法据此区分只读/写操作。
Result<nlohmann::json> CapabilityService::callCapability(std::string_view capability_name,
                                                         std::string_view operation,
                                                         const nlohmann::json& params)
{
	if (!implement_->initialized_) {
		return Result<nlohmann::json>::Error(Status::NOT_INITIALIZED);
	}

	// 为本次调用分配会话内唯一 ID
	static std::atomic<uint64_t> s_next_op_id{1};
	const std::string op_id =
	    std::to_string(s_next_op_id.fetch_add(1, std::memory_order_relaxed));

	SecurityContext ctx{
		.operation_id    = op_id,
		.capability_name = capability_name,
		.operation       = operation,
		.params          = params,
		.is_readonly     = false, // TODO: Phase 2 — 根据 operation 推导
	};

	std::string reason;
	SecurityAction pre = implement_->chain_.runPreHook(ctx, reason);

	if (pre == SecurityAction::Deny) {
		return Result<nlohmann::json>::Error(
		    Status(Status::OPERATION_DENIED, std::move(reason)));
	}

	if (pre == SecurityAction::NeedConfirm) {
		if (implement_->confirm_handler_ != nullptr) {
			// 阻塞当前线程等待用户确认；其他线程不受影响（各自独立阻塞）
			bool confirmed = implement_->confirm_handler_->requestConfirm(ctx, reason);
			if (!confirmed) {
				return Result<nlohmann::json>::Error(
				    Status(Status::OPERATION_DENIED, std::move(reason)));
			}
			// 用户确认：继续执行
		} else {
			// 未注入确认通道：直接返回 CONFIRM_REQUIRED，保持向后兼容
			return Result<nlohmann::json>::Error(
			    Status(Status::CONFIRM_REQUIRED, std::move(reason)));
		}
	}

	auto* cap = implement_->manager_.getCapability(capability_name);
	if (cap == nullptr) {
		return Result<nlohmann::json>::Error(Status::CAPABILITY_NOT_FOUND);
	}

	auto result = cap->execute(operation, params);
	if (result.failure()) {
		return result;
	}

	nlohmann::json response = result.value();
	SecurityAction post = implement_->chain_.runPostHook(ctx, response, reason);
	if (post == SecurityAction::Deny) {
		return Result<nlohmann::json>::Error(
		    Status(Status::OPERATION_DENIED, std::move(reason)));
	}
	// postHook 返回 NeedConfirm 视同 Pass：操作已执行完毕，无法回滚，
	// 二次确认在语义上无意义。若未来需要对出站数据做二次确认，
	// 应在 preHook 阶段基于操作类型提前拦截。
	return Result<nlohmann::json>::Ok(std::move(response));
}

} // namespace core
} // namespace clawshell
