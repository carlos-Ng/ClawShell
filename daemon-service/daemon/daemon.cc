#include "daemon.h"

#include "core/base/confirm.h"
#include "core/base/service.h"
#include "ipc/frame.h"
#include "ipc/pipe_security.h"
#include "ipc/windows_ipc_server.h"

#include "common/log.h"

#include <nlohmann/json.hpp>
#include <toml++/toml.hpp>

#include <atomic>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <string>
#include <thread>

#ifdef _WIN32
#  include <windows.h>
#else
#  error "Platform not supported: add POSIX sys/socket.h/sys/un.h implementation here"
#endif

namespace clawshell {
namespace daemon {

// ─── g_shutdown_event ─────────────────────────────────────────────────────
//
// 全局关闭事件句柄（Windows HANDLE）。
// SetConsoleCtrlHandler 回调触发时调用 SetEvent，
// Daemon::run() 的 WaitForSingleObject 随即返回，完成优雅停机。
#ifdef _WIN32
static HANDLE g_shutdown_event = INVALID_HANDLE_VALUE;

// consoleCtrlHandler Windows 控制台事件处理器。
//
// 入参:
// - ctrl_type: 控制事件类型（CTRL_C_EVENT / CTRL_BREAK_EVENT / CTRL_SHUTDOWN_EVENT 等）。
//
// 出参/返回:
// - TRUE：事件已处理，不再传递给后续处理器。
static BOOL WINAPI consoleCtrlHandler(DWORD ctrl_type)
{
	switch (ctrl_type) {
	case CTRL_C_EVENT:
	case CTRL_BREAK_EVENT:
	case CTRL_CLOSE_EVENT:
	case CTRL_SHUTDOWN_EVENT:
		LOG_INFO("received ctrl event {}, shutting down", ctrl_type);
		if (g_shutdown_event != INVALID_HANDLE_VALUE) {
			::SetEvent(g_shutdown_event);
		}
		return TRUE;
	default:
		return FALSE;
	}
}
#else
#  error "Platform not supported: add POSIX signal handler implementation here"
#endif

// ─── DaemonConfirmHandler ────────────────────────────────────────────────────
//
// NeedConfirm 确认通道的 daemon 端实现。
//
// 架构：
//   - 启动时在 confirm_pipe_path 上创建 Named Pipe 监听，专用于确认客户端。
//   - accept_thread_ 循环 ConnectNamedPipe，每次只保留最新连接的客户端管道句柄。
//   - requestConfirm 通过 call_mutex_ 串行化并发请求（同一时刻只有一条请求在处理）：
//     1. 检查是否有已连接的客户端，无则自动拒绝。
//     2. 向客户端发送 JSON 请求帧（含 id、capability、operation、params、reason）。
//     3. 阻塞读取客户端响应，超时或断开自动拒绝。
//     4. 解析 {"id": N, "confirmed": true/false}，返回确认结果。
//
// 线路协议：与主 IPC 相同的 Length-prefix framing（同 FrameCodec）。
//
// 线程安全设计（两把锁分离关注点）：
//   call_mutex_   : 串行化并发 requestConfirm 调用，全程持有（含阻塞 I/O 期间）。
//                   acceptLoop 在替换 client_handle_ 前也须获取 call_mutex_，
//                   确保替换发生时没有进行中的 requestConfirm 持有旧 handle，
//                   从而消除旧 handle 关闭与正在使用之间的竞态。
//   handle_mutex_ : 仅保护 client_handle_ 的读写（短暂加锁，无 I/O 在其中执行），
//                   使 stop() 能够随时获锁并 CancelIoEx 来中断阻塞的 readFrame。
//
// 关闭流程（两阶段中断）：
//   1. stop() 连接一个 dummy 客户端，解除 acceptLoop 在 ConnectNamedPipe 的阻塞。
//      若 acceptLoop 此时正阻塞于 call_mutex_（等待 requestConfirm 结束），
//      阶段 2 的 CancelIoEx 会先中断 requestConfirm 使其释放 call_mutex_，
//      随后 acceptLoop 自然退出。
//   2. stop() 在 handle_mutex_ 下调用 CancelIoEx + CloseHandle 中断 requestConfirm
//      中可能阻塞的 readFrame，并置 client_handle_ = INVALID_HANDLE_VALUE。
class DaemonConfirmHandler : public core::ConfirmHandlerInterface
{
public:
	explicit DaemonConfirmHandler(int timeout_ms = 60000)
	    : confirm_timeout_ms_(timeout_ms)
	{}

	~DaemonConfirmHandler() override { stop(); }

	// start 在给定管道路径上启动确认管道监听。
	//
	// 入参:
	// - pipe_path: Named Pipe 路径，格式 \\.\pipe\<name>。
	void start(const std::string& pipe_path)
	{
#ifdef _WIN32
		pipe_path_ = pipe_path;

		running_.store(true);
		accept_thread_ = std::thread(&DaemonConfirmHandler::acceptLoop, this);
		LOG_INFO("confirm handler: listening on {}", pipe_path_);
#else
#  error "Platform not supported"
#endif
	}

	// stop 停止确认通道，中断所有阻塞操作并等待 accept 线程退出。
	void stop()
	{
#ifdef _WIN32
		if (!running_.exchange(false)) {
			return;
		}
		// 阶段 1：连接一个 dummy 客户端，解除 acceptLoop 在 ConnectNamedPipe 的阻塞。
		// acceptLoop 检查 running_==false 后会关闭该连接并退出循环。
		if (!pipe_path_.empty()) {
			HANDLE dummy = ::CreateFileA(
			    pipe_path_.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
			    nullptr, OPEN_EXISTING, 0, nullptr);
			if (dummy != INVALID_HANDLE_VALUE) {
				::CloseHandle(dummy);
			}
		}
		// 阶段 2：CancelIoEx 中断 requestConfirm 中可能阻塞的 readFrame，
		// 再关闭 client_handle_。
		{
			std::lock_guard<std::mutex> lock(handle_mutex_);
			if (client_handle_ != INVALID_HANDLE_VALUE) {
				::CancelIoEx(client_handle_, nullptr);
				::CloseHandle(client_handle_);
				client_handle_ = INVALID_HANDLE_VALUE;
			}
		}
		if (accept_thread_.joinable()) {
			accept_thread_.join();
		}
#else
#  error "Platform not supported"
#endif
	}

	// requestConfirm 向已连接的客户端发出确认请求并阻塞等待响应。
	//
	// 入参:
	// - ctx:    本次调用的安全上下文。
	// - reason: 安全模块填写的拒绝原因，展示给用户供决策参考。
	//
	// 出参/返回:
	// - true：用户确认，操作继续。
	// - false：无客户端、发送失败、超时或用户拒绝，操作取消。
	bool requestConfirm(const core::SecurityContext& ctx,
	                    const std::string&           reason) override
	{
#ifdef _WIN32
		// call_mutex_ 保证同一时刻只有一个确认请求在处理（串行化调用）。
		// acceptLoop 在替换 client_handle_ 前也须持有此锁，
		// 因此 call_mutex_ 持有期间不会有旧 handle 被关闭的竞态。
		std::lock_guard<std::mutex> call_lock(call_mutex_);

		// Phase 1：取 handle 快照并准备请求报文（短暂持有 handle_mutex_，无 I/O）。
		HANDLE      handle;
		int         id;
		std::string req_json;
		{
			std::lock_guard<std::mutex> lock(handle_mutex_);
			if (client_handle_ == INVALID_HANDLE_VALUE) {
				LOG_WARN("confirm handler: no client connected, auto-denying");
				return false;
			}
			id     = ++next_request_id_;
			handle = client_handle_;

			nlohmann::json req = {
			    {"id",         id},
			    {"capability", std::string(ctx.capability_name)},
			    {"operation",  std::string(ctx.operation)},
			    {"params",     ctx.params},
			    {"reason",     reason},
			};
			req_json = req.dump();
		}
		// handle_mutex_ 已释放；后续所有 I/O 均在锁外执行，
		// 使 stop() 随时可获取 handle_mutex_ 并调用 CancelIoEx。

		// Phase 1.5：发送请求（handle_mutex_ 未持有）。
		auto write_st = ipc::FrameCodec::writeFrame(handle, req_json);
		if (!write_st.ok()) {
			LOG_WARN("confirm handler: failed to send request, auto-denying");
			{
				std::lock_guard<std::mutex> lock(handle_mutex_);
				if (client_handle_ == handle) {
					closeClientLocked();
				}
			}
			return false;
		}

		LOG_INFO("confirm handler: sent confirm request id={} op={}", id, ctx.operation);

		// Phase 2：等待响应（不持有 handle_mutex_）。
		// stop() 可在此期间获锁并调用 CancelIoEx 中断本次 ReadFile，
		// ReadFile 将返回 ERROR_OPERATION_ABORTED，readFrame 随即失败。
		auto resp_result = ipc::FrameCodec::readFrame(handle);

		// Phase 3：处理结果。
		if (!running_.load()) {
			return false;
		}
		if (resp_result.failure()) {
			LOG_WARN("confirm handler: no response (timeout or disconnect), auto-denying");
			{
				std::lock_guard<std::mutex> lock(handle_mutex_);
				if (client_handle_ == handle) {
					closeClientLocked();
				}
			}
			return false;
		}

		auto resp = nlohmann::json::parse(resp_result.value(), nullptr, false);
		if (resp.is_discarded()) {
			LOG_WARN("confirm handler: invalid response JSON, auto-denying");
			return false;
		}

		// 验证响应 id 与请求 id 一致，防止旧响应或恶意客户端伪造确认
		if (!resp.contains("id") || resp["id"] != id) {
			LOG_WARN("confirm handler: response id mismatch "
			         "(expected={}, got={}), auto-denying",
			         id,
			         resp.value("id", nlohmann::json(nullptr)).dump());
			return false;
		}

		bool confirmed = resp.value("confirmed", false);
		LOG_INFO("confirm handler: id={} confirmed={}", id, confirmed);
		return confirmed;
#else
#  error "Platform not supported"
#endif
	}

private:
	// acceptLoop 循环创建并等待客户端连接，每次只保留最新连接的管道句柄。
	//
	// 替换逻辑：
	//   替换 client_handle_ 前先获取 call_mutex_（等待进行中的 requestConfirm 完成），
	//   再获取 handle_mutex_ 执行替换，最后关闭旧 handle。
	//   这消除了旧 handle 在 requestConfirm 使用中被关闭的竞态条件。
	//
	// 关闭时序：
	//   stop() 的阶段 2（CancelIoEx）会中断进行中的 readFrame，
	//   使 requestConfirm 提前释放 call_mutex_，
	//   从而 acceptLoop 的 call_mutex_ 等待不会无限阻塞。
	void acceptLoop()
	{
#ifdef _WIN32
		while (running_.load()) {
			// 创建新的服务端管道实例（同步模式，不使用 FILE_FLAG_OVERLAPPED）
			// 使用当前用户专属 DACL，拒绝其他进程或用户连接到确认通道
			ipc::PipeSecurityContext sec;
			if (!sec.init()) {
				LOG_WARN("confirm handler: failed to build pipe DACL, "
				         "falling back to default security");
			}
			HANDLE pipe = ::CreateNamedPipeA(
			    pipe_path_.c_str(),
			    PIPE_ACCESS_DUPLEX,
			    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
			    PIPE_UNLIMITED_INSTANCES,
			    65536, 65536,
			    static_cast<DWORD>(confirm_timeout_ms_),
			    sec.ptr());
			if (pipe == INVALID_HANDLE_VALUE) {
				if (running_.load()) {
					LOG_ERROR("confirm handler: CreateNamedPipe failed: {}",
					          ::GetLastError());
				}
				break;
			}

			// 阻塞等待客户端连接（stop() 通过 dummy 连接解除此阻塞）
			BOOL connected = ::ConnectNamedPipe(pipe, nullptr);
			if (!connected) {
				DWORD err = ::GetLastError();
				if (err != ERROR_PIPE_CONNECTED) {
					::CloseHandle(pipe);
					if (!running_.load()) {
						break;
					}
					if (err != ERROR_OPERATION_ABORTED) {
						LOG_ERROR("confirm handler: ConnectNamedPipe error {}", err);
					}
					continue;
				}
			}

			// 若正在关闭，此连接为 dummy 连接，直接关闭并退出
			if (!running_.load()) {
				::CloseHandle(pipe);
				break;
			}

			// 替换 client_handle_：先持有 call_mutex_ 确保无进行中的 requestConfirm，
			// 再持有 handle_mutex_ 执行原子替换，之后安全关闭旧 handle。
			HANDLE old_handle;
			{
				std::lock_guard<std::mutex> call_lock(call_mutex_);
				std::lock_guard<std::mutex> handle_lock(handle_mutex_);
				old_handle     = client_handle_;
				client_handle_ = pipe;
			}
			if (old_handle != INVALID_HANDLE_VALUE) {
				::DisconnectNamedPipe(old_handle);
				::CloseHandle(old_handle);
			}
			LOG_INFO("confirm handler: client connected");
		}
#else
#  error "Platform not supported"
#endif
	}

	// closeClientLocked 关闭当前客户端管道句柄，须在持有 handle_mutex_ 时调用。
	void closeClientLocked()
	{
#ifdef _WIN32
		if (client_handle_ != INVALID_HANDLE_VALUE) {
			::DisconnectNamedPipe(client_handle_);
			::CloseHandle(client_handle_);
			client_handle_ = INVALID_HANDLE_VALUE;
		}
#else
#  error "Platform not supported"
#endif
	}

	std::string       pipe_path_;
	std::atomic<bool> running_{false};
	std::thread       accept_thread_;
	std::mutex        call_mutex_;    // 串行化并发 requestConfirm 调用
	std::mutex        handle_mutex_;  // 保护 client_handle_ 的读写
	int               next_request_id_ = 0;
	int               confirm_timeout_ms_;

#ifdef _WIN32
	HANDLE client_handle_ = INVALID_HANDLE_VALUE;  // 由 handle_mutex_ 保护
#else
#  error "Platform not supported"
#endif
};

// ─── Implement ──────────────────────────────────────────────────────────────

struct Daemon::Implement
{
	core::CapabilityService service_;
	ipc::WindowsIpcServer   ipc_server_;
	DaemonConfirmHandler    confirm_handler_;
	DaemonConfig            config_;
	std::atomic<bool>       running_{false};

	// parseToml 解析 TOML 配置文件，将未被 CLI 覆盖的字段填充入 config。
	//
	// 入参:
	// - config: 已含 CLI 覆盖值的 DaemonConfig，函数只填充尚未被覆盖的字段。
	//
	// 出参/返回:
	// - Status::Ok()：解析成功，或配置文件不存在（允许无配置启动）。
	// - Status(CONFIG_PARSE_ERROR)：配置文件存在但格式错误。
	// - Status(IO_ERROR)：文件存在但读取失败（权限等问题）。
	static Status parseToml(DaemonConfig& config);

	// buildModuleConfig 从 TOML 模块表中提取自定义参数，填充 ModuleConfig。
	//
	// 入参:
	// - tbl:  TOML 模块表节（一个 [[modules]] 条目）。
	// - spec: 输出参数，填充 spec.params。
	static void buildModuleConfig(const toml::table& tbl, core::ModuleSpec& spec);

	// registerCapabilityHandlers 向 IPC server 注册所有已加载 capability 的 handler。
	void registerCapabilityHandlers();
};

// ─── Implement 方法实现 ──────────────────────────────────────────────────────

// parseToml 解析 TOML 配置文件，将未被 CLI 覆盖的字段填充入 config。
// 先用 std::ifstream 检查文件是否可打开，以区分"文件不存在"（允许）与"格式错误"（致命）。
Status Daemon::Implement::parseToml(DaemonConfig& config)
{
	// 预检：文件不存在时直接返回 Ok，保留已有的 CLI 覆盖值与内置默认值
	{
		std::ifstream test(config.config_path);
		if (!test.good()) {
			LOG_DEBUG("config file '{}' not found, using defaults/cli values",
			          config.config_path);
			return Status::Ok();
		}
	}

	toml::table tbl;
	try {
		tbl = toml::parse_file(config.config_path);
	} catch (const toml::parse_error& e) {
		LOG_ERROR("TOML parse error in '{}': {}", config.config_path, e.description().data());
		return Status(Status::CONFIG_PARSE_ERROR);
	} catch (const std::exception& e) {
		LOG_ERROR("failed to read config file '{}': {}", config.config_path, e.what());
		return Status(Status::IO_ERROR);
	}

	// [daemon] 节 — 只填充尚未被 CLI 覆盖（等于 DEFAULT_* 常量）的字段
	if (const auto* daemon_tbl = tbl.get_as<toml::table>("daemon")) {
		auto fill_str = [&](const char* key, std::string& field,
		                    const char* default_val) {
			if (field == default_val) {
				if (auto v = daemon_tbl->get_as<std::string>(key)) {
					field = **v;
				}
			}
		};
		auto fill_int = [&](const char* key, int& field, int default_val) {
			if (field == default_val) {
				if (auto v = daemon_tbl->get_as<int64_t>(key)) {
					field = static_cast<int>(**v);
				}
			}
		};

		fill_str("socket_path",         config.socket_path,         DaemonConfig::DEFAULT_SOCKET_PATH);
		fill_str("log_level",           config.log_level,           DaemonConfig::DEFAULT_LOG_LEVEL);
		fill_str("module_dir",          config.module_dir,          DaemonConfig::DEFAULT_MODULE_DIR);
		fill_str("confirm_socket_path", config.confirm_socket_path, DaemonConfig::DEFAULT_CONFIRM_SOCK_PATH);
		fill_int("thread_pool_size",    config.thread_pool_size,    DaemonConfig::DEFAULT_THREAD_POOL_SIZE);
	}

	// [[modules]] 数组
	if (const auto* modules_arr = tbl.get_as<toml::array>("modules")) {
		for (const auto& elem : *modules_arr) {
			const auto* mod_tbl = elem.as_table();
			if (mod_tbl == nullptr) {
				continue;
			}
			const auto* name_node = mod_tbl->get_as<std::string>("name");
			if (name_node == nullptr || (*name_node)->empty()) {
				continue;
			}
			core::ModuleSpec spec;
			spec.name = **name_node;
			if (const auto* prio = mod_tbl->get_as<int64_t>("priority")) {
				spec.priority = static_cast<int>(**prio);
			}
			buildModuleConfig(*mod_tbl, spec);
			config.core.modules.push_back(std::move(spec));
		}
	}

	return Status::Ok();
}

// buildModuleConfig 从 TOML 模块表中提取自定义参数（跳过内置保留键）。
void Daemon::Implement::buildModuleConfig(const toml::table& tbl, core::ModuleSpec& spec)
{
	for (const auto& [k, v] : tbl) {
		// 内置保留键，不进入 ModuleConfig
		if (k == "name" || k == "priority") {
			continue;
		}
		std::string key(k.str());
		if (v.is_string()) {
			spec.params.set(key, std::string(**v.as_string()));
		} else if (v.is_integer()) {
			spec.params.set(key, **v.as_integer());
		} else if (v.is_floating_point()) {
			spec.params.set(key, **v.as_floating_point());
		} else if (v.is_boolean()) {
			spec.params.set(key, **v.as_boolean());
		}
	}
}

// registerCapabilityHandlers 为每个已加载的 capability 向 IPC server 注册 handler。
void Daemon::Implement::registerCapabilityHandlers()
{
	for (const auto& cap_name : service_.capabilityNames()) {
		ipc_server_.registerModule(
		    cap_name,
		    [this, cap_name](const std::string& operation,
		                     const nlohmann::json& params) -> Result<nlohmann::json> {
			    return service_.callCapability(cap_name, operation, params);
		    });
		LOG_INFO("registered ipc handler for capability: {}", cap_name);
	}
}

// ─── Daemon 公开接口 ─────────────────────────────────────────────────────────

Daemon::Daemon()
	: implement_(std::make_unique<Implement>())
{
}

Daemon::~Daemon()
{
	stop();
}

// init 完成 daemon 初始化：解析 TOML、初始化日志与 core 层、注册 IPC handler。
Status Daemon::init(DaemonConfig config)
{
	// 1. 解析 TOML，将未被 CLI 覆盖的字段填入 config
	auto parse_status = Implement::parseToml(config);
	if (!parse_status.ok()) {
		return parse_status;
	}

	// 2. 同步 module_dir 到 core config
	config.core.module_dir = config.module_dir;

	// 3. 初始化日志系统
	log::Config log_cfg;
	log_cfg.level       = log::levelFromString(config.log_level);
	log_cfg.output_mode = config.foreground ? log::Mode::CONSOLE : log::Mode::FILE;
	log::init(log_cfg);

	LOG_INFO("daemon starting, config: {}", config.config_path);
	LOG_INFO("socket: {}, thread_pool: {}, module_dir: {}",
	         config.socket_path, config.thread_pool_size, config.module_dir);

	// 4. 初始化 CapabilityService（动态加载所有模块）
	auto init_result = implement_->service_.init(config.core);
	if (init_result.failure()) {
		LOG_ERROR("capability service init failed: {}", init_result.error().message);
		return init_result.error();
	}

	// 5. 启动用户确认通道并注入 CapabilityService
	implement_->confirm_handler_.start(config.confirm_socket_path);
	implement_->service_.setConfirmHandler(&implement_->confirm_handler_);

	// 6. 向 IPC server 注册所有 capability handler
	implement_->registerCapabilityHandlers();

	implement_->config_ = std::move(config);
	return Status::Ok();
}

// run 启动 IPC 服务并阻塞，直到收到 Ctrl+C / 关闭事件后优雅停机。
//
// Windows 下通过 SetConsoleCtrlHandler + WaitForSingleObject(g_shutdown_event) 实现。
bool Daemon::run()
{
	const auto& config = implement_->config_;

#ifdef _WIN32
	// 创建手动重置事件，用于 consoleCtrlHandler → run() 的通知
	g_shutdown_event = ::CreateEventA(nullptr, TRUE, FALSE, nullptr);
	if (g_shutdown_event == INVALID_HANDLE_VALUE) {
		LOG_ERROR("failed to create shutdown event: {}", ::GetLastError());
		return false;
	}

	// 注册控制台 Ctrl 事件处理器
	if (!::SetConsoleCtrlHandler(consoleCtrlHandler, TRUE)) {
		LOG_ERROR("failed to register console ctrl handler: {}", ::GetLastError());
		::CloseHandle(g_shutdown_event);
		g_shutdown_event = INVALID_HANDLE_VALUE;
		return false;
	}
#else
#  error "Platform not supported: add POSIX sigwait implementation here"
#endif

	auto start_status = implement_->ipc_server_.start(
	    config.socket_path, config.thread_pool_size);
	if (!start_status.ok()) {
		LOG_ERROR("ipc server start failed: {}", start_status.message);
#ifdef _WIN32
		::CloseHandle(g_shutdown_event);
		g_shutdown_event = INVALID_HANDLE_VALUE;
#endif
		return false;
	}
	LOG_INFO("daemon running, listening on {}", config.socket_path);

	implement_->running_.store(true);

#ifdef _WIN32
	// 阻塞等待关闭事件（由 consoleCtrlHandler 触发）
	::WaitForSingleObject(g_shutdown_event, INFINITE);
	LOG_INFO("shutdown event received, shutting down");

	// 清理 Ctrl 事件处理器和事件句柄
	::SetConsoleCtrlHandler(consoleCtrlHandler, FALSE);
	::CloseHandle(g_shutdown_event);
	g_shutdown_event = INVALID_HANDLE_VALUE;
#else
#  error "Platform not supported: add POSIX sigwait implementation here"
#endif

	stop();
	return true;
}

// stop 触发优雅停机：停止 IPC server 并释放 core 资源。
//
// confirm_handler_.stop() 在 running_ 门控之外调用，
// 以覆盖 init() 成功但 run() 中 ipc_server_.start() 失败的情形：
// 此时 running_ 从未被置为 true，若受 running_ 门控，confirm_handler_
// 的 accept 线程将无法被 join，导致线程泄漏。
// DaemonConfirmHandler::stop() 自身是幂等的（running_ 原子交换保护），
// 多次调用安全。
void Daemon::stop()
{
	// 始终尝试停止确认通道（init() 后 run() 失败时也须清理）
	implement_->confirm_handler_.stop();

	if (!implement_->running_.exchange(false)) {
		return;
	}
	LOG_INFO("daemon stopping");
	implement_->ipc_server_.stop();
	implement_->service_.release();
	LOG_INFO("daemon stopped");
}

} // namespace daemon
} // namespace clawshell
