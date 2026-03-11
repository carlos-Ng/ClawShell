#include "daemon.h"

#include "core/base/service.h"
#include "core/task_registry.h"
#include "ipc/ui_service.h"
#include "ipc/windows_ipc_server.h"

#include "common/log.h"

#include <nlohmann/json.hpp>
#include <toml++/toml.hpp>

#include <atomic>
#include <chrono>
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
#ifdef _WIN32
static HANDLE g_shutdown_event = INVALID_HANDLE_VALUE;

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

// ─── Implement ──────────────────────────────────────────────────────────────

struct Daemon::Implement
{
	core::CapabilityService  service_;
	core::TaskRegistry       task_registry_;
	ipc::WindowsIpcServer    ipc_server_;
	ipc::UIService           ui_service_;
	DaemonConfig             config_;
	std::atomic<bool>        running_{false};

	static Status parseToml(DaemonConfig& config);
	static void   buildModuleConfig(const toml::table& tbl, core::ModuleSpec& spec);

	// registerHandlers 向 IPC server 注册全部处理器：
	//   - 每个 capability 的 CapabilityHandler（带 task_id）
	//   - TaskBeginHandler（创建任务，推送 UIService 事件）
	//   - TaskEndHandler（结束任务，推送 UIService 事件）
	void registerHandlers();
};

// ─── Implement 方法实现 ──────────────────────────────────────────────────────

Status Daemon::Implement::parseToml(DaemonConfig& config)
{
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

	if (const auto* daemon_tbl = tbl.get_as<toml::table>("daemon")) {
		auto fill_str = [&](const char* key, std::string& field, const char* default_val) {
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

		fill_str("socket_path",      config.socket_path,      DaemonConfig::DEFAULT_SOCKET_PATH);
		fill_str("log_level",        config.log_level,        DaemonConfig::DEFAULT_LOG_LEVEL);
		fill_str("module_dir",       config.module_dir,       DaemonConfig::DEFAULT_MODULE_DIR);
		fill_int("thread_pool_size", config.thread_pool_size, DaemonConfig::DEFAULT_THREAD_POOL_SIZE);
	}

	if (const auto* ui_tbl = tbl.get_as<toml::table>("ui")) {
		auto fill_str = [&](const char* key, std::string& field, const char* default_val) {
			if (field == default_val) {
				if (auto v = ui_tbl->get_as<std::string>(key)) {
					field = **v;
				}
			}
		};
		auto fill_int = [&](const char* key, int& field, int default_val) {
			if (field == default_val) {
				if (auto v = ui_tbl->get_as<int64_t>(key)) {
					field = static_cast<int>(**v);
				}
			}
		};
		fill_str("pipe_path",    config.ui_pipe_path,    DaemonConfig::DEFAULT_UI_PIPE_PATH);
		fill_str("timeout_mode", config.ui_timeout_mode, DaemonConfig::DEFAULT_UI_TIMEOUT_MODE);
		fill_int("timeout_secs", config.ui_timeout_secs, DaemonConfig::DEFAULT_UI_TIMEOUT_SECS);
	}

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

void Daemon::Implement::buildModuleConfig(const toml::table& tbl, core::ModuleSpec& spec)
{
	for (const auto& [k, v] : tbl) {
		if (k == "name" || k == "priority") {
			continue;
		}
		std::string key(k.str());
		if (v.is_string())              { spec.params.set(key, std::string(**v.as_string())); }
		else if (v.is_integer())        { spec.params.set(key, **v.as_integer()); }
		else if (v.is_floating_point()) { spec.params.set(key, **v.as_floating_point()); }
		else if (v.is_boolean())        { spec.params.set(key, **v.as_boolean()); }
	}
}

// registerHandlers 注册全部 Channel 1 处理器到 IPC server。
void Daemon::Implement::registerHandlers()
{
	// ── 能力处理器（带 task_id）────────────────────────────────────────────────
	for (const auto& cap_name : service_.capabilityNames()) {
		ipc_server_.registerCapability(
		    cap_name,
		    [this, cap_name](const std::string&    task_id,
		                     const std::string&    operation,
		                     const nlohmann::json& params) -> Result<nlohmann::json> {
			    return service_.callCapability(cap_name, operation, params, task_id);
		    });
		LOG_INFO("registered capability handler: {}", cap_name);
	}

	// ── 任务开始处理器 ──────────────────────────────────────────────────────────
	ipc_server_.setTaskBeginHandler(
	    [this](const std::string& description,
	           const std::string& root_description,
	           const std::string& parent_task_id,
	           const std::string& session_id) -> std::string {

		    const std::string task_id = task_registry_.beginTask(
		        description, root_description, parent_task_id, session_id);

		    // 查找任务上下文以获取继承后的 root_description
		    const auto* task_ctx = task_registry_.findTask(task_id);
		    const std::string& ui_root_desc =
		        (task_ctx != nullptr && !task_ctx->root_description.empty())
		        ? task_ctx->root_description
		        : root_description;

		    ui_service_.push(ipc::UIMessageFactory::createTaskBegin(task_id, ui_root_desc));

		    LOG_INFO("task begin: task_id='{}' session='{}' desc='{}'",
		             task_id, session_id, description);
		    return task_id;
	    });

	// ── 任务结束处理器 ──────────────────────────────────────────────────────────
	ipc_server_.setTaskEndHandler(
	    [this](const std::string& task_id, bool success) {
		    task_registry_.endTask(task_id);
		    ui_service_.push(ipc::UIMessageFactory::createTaskEnd(task_id));
		    LOG_INFO("task end: task_id='{}' success={}", task_id, success);
	    });
}

// ─── Daemon 公开接口 ─────────────────────────────────────────────────────────

Daemon::Daemon()
	: implement_(std::make_unique<Implement>())
{}

Daemon::~Daemon()
{
	stop();
}

Status Daemon::init(DaemonConfig config)
{
	// 1. 解析 TOML
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

	// 5. 将 TaskRegistry 注入 CapabilityService
	implement_->service_.setTaskRegistry(&implement_->task_registry_);

	// 6. 启动 UIService（Channel 2）
	{
		ipc::ConfirmTimeoutMode timeout_mode = ipc::ConfirmTimeoutMode::TIMEOUT_DENY;
		if (config.ui_timeout_mode == "wait_forever") {
			timeout_mode = ipc::ConfirmTimeoutMode::WAIT_FOREVER;
		} else if (config.ui_timeout_mode == "timeout_allow") {
			timeout_mode = ipc::ConfirmTimeoutMode::TIMEOUT_ALLOW;
		}

		auto ui_status = implement_->ui_service_.start(
		    config.ui_pipe_path,
		    timeout_mode,
		    std::chrono::seconds(config.ui_timeout_secs),
		    [this]() -> std::string {
			    return ipc::UIMessageFactory::createStatus(implement_->running_.load());
		    });

		if (!ui_status.ok()) {
			LOG_WARN("ui service start failed: {}, UI features disabled", ui_status.message);
		} else {
			implement_->service_.setUIService(&implement_->ui_service_);
			LOG_INFO("ui service listening on {}", config.ui_pipe_path);
		}
	}

	// 7. 注册所有 Channel 1 处理器（capability + beginTask + endTask）
	implement_->registerHandlers();

	implement_->config_ = std::move(config);
	return Status::Ok();
}

bool Daemon::run()
{
	const auto& config = implement_->config_;

#ifdef _WIN32
	g_shutdown_event = ::CreateEventA(nullptr, TRUE, FALSE, nullptr);
	if (g_shutdown_event == INVALID_HANDLE_VALUE) {
		LOG_ERROR("failed to create shutdown event: {}", ::GetLastError());
		return false;
	}
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
	::WaitForSingleObject(g_shutdown_event, INFINITE);
	LOG_INFO("shutdown event received, shutting down");
	::SetConsoleCtrlHandler(consoleCtrlHandler, FALSE);
	::CloseHandle(g_shutdown_event);
	g_shutdown_event = INVALID_HANDLE_VALUE;
#else
#  error "Platform not supported: add POSIX sigwait implementation here"
#endif

	stop();
	return true;
}

void Daemon::stop()
{
	implement_->ui_service_.stop();

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
