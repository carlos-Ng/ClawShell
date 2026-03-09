#include "ipc/windows_ipc_server.h"
#include "frame.h"
#include "json_rpc_status_converter.h"

#include "common/log.h"

#include <nlohmann/json.hpp>

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <queue>
#include <set>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <windows.h>
#include <objbase.h>

#include "pipe_security.h"

namespace clawshell {
namespace ipc {



// ─── Implement ──────────────────────────────────────────────────────────────

struct WindowsIpcServer::Implement
{
	std::unordered_map<std::string, ModuleHandler> handlers_;
	std::mutex                                     handlers_mutex_;

	HANDLE            listen_handle_ = INVALID_HANDLE_VALUE;
	std::string       pipe_name_;

	std::atomic<bool> running_{false};

	std::thread              accept_thread_;
	std::vector<std::thread> workers_;

	std::queue<HANDLE>       work_queue_;
	std::mutex               queue_mutex_;
	std::condition_variable  queue_cv_;

	// current_accept_handle_：acceptLoop 当前正在 ConnectNamedPipe 等待的管道句柄。
	// stop() 通过此字段调用 CancelIoEx，无论是第几轮迭代都能可靠中断。
	// 由 current_accept_mutex_ 保护。
	HANDLE    current_accept_handle_ = INVALID_HANDLE_VALUE;
	std::mutex current_accept_mutex_;

	// 活跃连接集合：用于 stop() 时 CancelIoEx 正在 processConnection 持有的 HANDLE，
	// 以中断其阻塞的 readFrame，使 worker 线程能及时退出
	std::set<HANDLE> active_handles_;
	std::mutex       active_handles_mutex_;

	JsonRpcStatusConverter converter_;

	// ── 内部方法 ────────────────────────────────────────────────────────────

	// bindAndListen 创建 Named Pipe 服务端实例，准备接受连接。
	//
	// 入参:
	// - pipe_name: Named Pipe 路径，格式 \\.\pipe\<name>。
	//
	// 出参/返回:
	// - Status::Ok()：成功。
	// - Status(error)：创建失败。
	Status bindAndListen(const std::string& pipe_name);

	// acceptLoop 在独立线程中循环接受新连接，将 HANDLE 投入工作队列。
	void acceptLoop();

	// workerLoop 工作线程主循环，从队列取 HANDLE 并处理连接。
	void workerLoop();

	// processConnection 处理单个连接的完整生命周期（多次请求-响应）。
	//
	// 入参:
	// - handle: 已接受的连接 HANDLE，函数返回时负责关闭。
	void processConnection(HANDLE handle);

	// handleRequest 解析一条 JSON-RPC 2.0 请求字符串并返回响应字符串。
	//
	// 入参:
	// - request_str: 原始 JSON 字符串。
	//
	// 出参/返回:
	// - 响应 JSON 字符串；通知类请求返回空字符串（无需响应）。
	std::string handleRequest(const std::string& request_str);

	// dispatchToModule 解析 method 字段并路由到对应模块处理器。
	//
	// 入参:
	// - id:     JSON-RPC request id（用于构造响应）。
	// - method: 完整方法名，格式为 "module.operation"。
	// - params: 请求参数 JSON 对象。
	//
	// 出参/返回:
	// - 响应 JSON 字符串。
	std::string dispatchToModule(const nlohmann::json& id,
	                             const std::string& method,
	                             const nlohmann::json& params);

	// makeSuccessResponse 构造 JSON-RPC 2.0 成功响应字符串。
	static std::string makeSuccessResponse(const nlohmann::json& id,
	                                       const nlohmann::json& result);

	// makeErrorResponse 构造 JSON-RPC 2.0 错误响应字符串。
	static std::string makeErrorResponse(const nlohmann::json& id,
	                                     int code,
	                                     const std::string& msg);
};

// ─── Implement 方法实现 ──────────────────────────────────────────────────────

// bindAndListen 创建 Named Pipe 服务端实例（第一个实例，用于 accept 循环）。
// 使用 PipeSecurityContext 限制连接权限为当前用户，防止其他进程或低权限进程接入。
Status WindowsIpcServer::Implement::bindAndListen(const std::string& pipe_name)
{
	pipe_name_ = pipe_name;

	PipeSecurityContext sec;
	if (!sec.init()) {
		LOG_WARN("ipc server: failed to build pipe DACL, falling back to default security");
	}

	// 创建第一个管道实例：后续 acceptLoop 中会为每个连接创建新实例
	listen_handle_ = ::CreateNamedPipeA(
	    pipe_name_.c_str(),
	    PIPE_ACCESS_DUPLEX,
	    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
	    PIPE_UNLIMITED_INSTANCES,
	    65536, 65536,
	    0,        // nDefaultTimeOut：0 = 50ms 默认
	    sec.ptr() // 当前用户专属 DACL
	);
	if (listen_handle_ == INVALID_HANDLE_VALUE) {
		return Status(Status::IO_ERROR, "failed to create named pipe");
	}
	return Status::Ok();
}

// acceptLoop 循环等待客户端连接，将已连接的管道 HANDLE 投入工作队列。
// 每次连接后立即创建下一个管道实例以等待新客户端，与 POSIX accept 语义对应。
//
// 死锁修复：
//   每次 ConnectNamedPipe 前，将 current 写入 current_accept_handle_（互斥保护），
//   使 stop() 无论在哪轮迭代都能通过 CancelIoEx 可靠中断阻塞。
//   原先只对 listen_handle_ 调用 CancelIoEx，在第一次连接后 current != listen_handle_，
//   CancelIoEx 无效，导致 accept_thread_.join() 永远阻塞。
//
// handle 泄漏修复：
//   用 current_consumed 标记 current 是否已入队。若循环因 running_=false 或错误退出时
//   current 尚未入队，主动关闭该句柄防止泄漏。
void WindowsIpcServer::Implement::acceptLoop()
{
	HANDLE current          = listen_handle_;
	bool   current_consumed = true; // listen_handle_ 由 stop() 负责关闭，视为"已消费"

	while (running_.load()) {
		// 注册当前等待句柄，使 stop() 可以通过 CancelIoEx 中断本次 ConnectNamedPipe
		{
			std::lock_guard<std::mutex> lk(current_accept_mutex_);
			current_accept_handle_ = current;
		}

		BOOL connected = ::ConnectNamedPipe(current, nullptr);

		// 解注册：ConnectNamedPipe 已返回（无论成功与否），stop() 不再需要 cancel 此 handle
		{
			std::lock_guard<std::mutex> lk(current_accept_mutex_);
			current_accept_handle_ = INVALID_HANDLE_VALUE;
		}

		if (!connected) {
			DWORD err = ::GetLastError();
			if (err == ERROR_PIPE_CONNECTED) {
				// 客户端在 ConnectNamedPipe 之前已连接，正常继续
			} else {
				// 管道已关闭或发生错误，退出循环
				if (err != ERROR_OPERATION_ABORTED && err != ERROR_BROKEN_PIPE) {
					LOG_ERROR("acceptLoop: ConnectNamedPipe failed with error {}", err);
				}
				// current 未入队，若非 listen_handle_ 则需要关闭
				if (!current_consumed) {
					::CloseHandle(current);
				}
				break;
			}
		}

		// 将已连接的管道 HANDLE 推入工作队列
		{
			std::lock_guard<std::mutex> lock(queue_mutex_);
			work_queue_.push(current);
		}
		queue_cv_.notify_one();
		current_consumed = true;

		// 检查关闭标志（stop() 可能在队列推入后才将 running_ 置 false）
		if (!running_.load()) {
			break;
		}

		// 为下一个客户端创建新的管道实例（沿用相同的 DACL 配置）
		PipeSecurityContext sec;
		if (!sec.init()) {
			LOG_WARN("acceptLoop: failed to build pipe DACL, falling back to default security");
		}
		current = ::CreateNamedPipeA(
		    pipe_name_.c_str(),
		    PIPE_ACCESS_DUPLEX,
		    PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
		    PIPE_UNLIMITED_INSTANCES,
		    65536, 65536,
		    0, sec.ptr());
		if (current == INVALID_HANDLE_VALUE) {
			if (running_.load()) {
				LOG_ERROR("acceptLoop: CreateNamedPipe failed with error {}",
				          ::GetLastError());
			}
			break;
		}
		current_consumed = false; // 新句柄尚未入队
	}
}

// workerLoop 工作线程主循环：等待队列有任务，取出 HANDLE 处理连接；
// 取到哨兵（INVALID_HANDLE_VALUE）时退出。
//
// 每个工作线程独立调用 CoInitializeEx，以确保 IUIAutomation 等 COM 对象
// 可在 MTA（多线程套间）中安全使用。
// S_FALSE 表示本线程已初始化（不视为错误）；CoUninitialize 总是与成功的
// CoInitializeEx 成对调用。
void WindowsIpcServer::Implement::workerLoop()
{
	HRESULT com_hr = ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);

	while (true) {
		HANDLE handle = INVALID_HANDLE_VALUE;
		{
			std::unique_lock<std::mutex> lock(queue_mutex_);
			queue_cv_.wait(lock, [this] { return !work_queue_.empty(); });
			handle = work_queue_.front();
			work_queue_.pop();
		}
		if (handle == INVALID_HANDLE_VALUE) {
			break;
		}
		processConnection(handle);
	}

	if (SUCCEEDED(com_hr) || com_hr == S_FALSE) {
		::CoUninitialize();
	}
}

// processConnection 处理单个连接的完整请求-响应生命周期。
// 连接 HANDLE 在进入时登记到 active_handles_，退出时移除，保证 stop() 可中断进行中的连接。
void WindowsIpcServer::Implement::processConnection(HANDLE handle)
{
	{
		std::lock_guard<std::mutex> lock(active_handles_mutex_);
		active_handles_.insert(handle);
	}

	while (running_.load()) {
		auto result = FrameCodec::readFrame(handle);
		if (result.failure()) {
			break;
		}
		std::string response = handleRequest(result.value());
		if (response.empty()) {
			continue;
		}
		if (!FrameCodec::writeFrame(handle, response).ok()) {
			break;
		}
	}

	{
		std::lock_guard<std::mutex> lock(active_handles_mutex_);
		active_handles_.erase(handle);
	}

	::DisconnectNamedPipe(handle);
	::CloseHandle(handle);
}

// handleRequest 解析 JSON-RPC 2.0 请求并返回响应字符串。
std::string WindowsIpcServer::Implement::handleRequest(const std::string& request_str)
{
	nlohmann::json id = nullptr;
	try {
		auto req = nlohmann::json::parse(request_str);
		if (!req.is_object()) {
			return makeErrorResponse(id, -32600, "invalid request: expected JSON object");
		}
		if (req.contains("id")) {
			id = req["id"];
		}
		if (!req.contains("jsonrpc") || req["jsonrpc"] != "2.0") {
			return makeErrorResponse(id, -32600, "invalid request: jsonrpc field must be \"2.0\"");
		}
		if (!req.contains("method") || !req["method"].is_string()) {
			return makeErrorResponse(id, -32600, "invalid request: method must be a string");
		}
		bool is_notification = !req.contains("id");
		std::string method = req["method"].get<std::string>();
		nlohmann::json params = req.value("params", nlohmann::json::object());

		std::string response = dispatchToModule(id, method, params);
		return is_notification ? "" : response;

	} catch (const nlohmann::json::parse_error&) {
		return makeErrorResponse(nullptr, -32700, "parse error: invalid JSON");
	} catch (const std::exception& e) {
		return makeErrorResponse(id, -32603, std::string("internal error: ") + e.what());
	}
}

// dispatchToModule 将 "module.operation" 方法名拆分后路由到对应模块处理器。
std::string WindowsIpcServer::Implement::dispatchToModule(const nlohmann::json& id,
                                                          const std::string& method,
                                                          const nlohmann::json& params)
{
	auto dot_pos = method.find('.');
	if (dot_pos == std::string::npos || dot_pos == 0 || dot_pos == method.size() - 1) {
		return makeErrorResponse(id, -32601,
		                         "method not found: invalid format, expected module.operation");
	}
	std::string module_name = method.substr(0, dot_pos);
	std::string operation   = method.substr(dot_pos + 1);

	ModuleHandler handler;
	{
		std::lock_guard<std::mutex> lock(handlers_mutex_);
		auto it = handlers_.find(module_name);
		if (it == handlers_.end()) {
			return makeErrorResponse(id, -32601,
			                         "method not found: module \"" + module_name + "\" not registered");
		}
		handler = it->second;
	}

	auto result = handler(operation, params);
	if (result.success()) {
		return makeSuccessResponse(id, result.value());
	}
	auto error_obj = converter_.convert(result.error());
	return makeErrorResponse(id,
	                         error_obj["code"].get<int>(),
	                         error_obj["message"].get<std::string>());
}

// makeSuccessResponse 构造 JSON-RPC 2.0 成功响应。
std::string WindowsIpcServer::Implement::makeSuccessResponse(const nlohmann::json& id,
                                                             const nlohmann::json& result)
{
	return nlohmann::json{{"jsonrpc", "2.0"}, {"id", id}, {"result", result}}.dump();
}

// makeErrorResponse 构造 JSON-RPC 2.0 错误响应。
std::string WindowsIpcServer::Implement::makeErrorResponse(const nlohmann::json& id,
                                                           int code,
                                                           const std::string& msg)
{
	return nlohmann::json{
		{"jsonrpc", "2.0"},
		{"id", id},
		{"error", {{"code", code}, {"message", msg}}}
	}.dump();
}

// ─── WindowsIpcServer 公开接口 ───────────────────────────────────────────────

WindowsIpcServer::WindowsIpcServer()
	: implement_(std::make_unique<Implement>())
{
}

WindowsIpcServer::~WindowsIpcServer()
{
	stop();
}

// registerModule 注册一个模块的请求处理器（须在 start() 前调用）。
void WindowsIpcServer::registerModule(std::string_view module_name, ModuleHandler handler)
{
	std::lock_guard<std::mutex> lock(implement_->handlers_mutex_);
	implement_->handlers_[std::string(module_name)] = std::move(handler);
}

// start 创建 Named Pipe，启动 Accept 线程和工作线程池。
Status WindowsIpcServer::start(std::string_view pipe_path, int thread_pool_size)
{
	if (implement_->running_.load()) {
		return Status(Status::INTERNAL_ERROR, "server is already running");
	}
	if (thread_pool_size < 1) {
		return Status(Status::INVALID_ARGUMENT, "thread_pool_size must be at least 1");
	}
	auto status = implement_->bindAndListen(std::string(pipe_path));
	if (!status.ok()) {
		return status;
	}
	implement_->running_.store(true);
	implement_->accept_thread_ = std::thread([this] { implement_->acceptLoop(); });
	implement_->workers_.reserve(static_cast<size_t>(thread_pool_size));
	for (int i = 0; i < thread_pool_size; ++i) {
		implement_->workers_.emplace_back([this] { implement_->workerLoop(); });
	}
	LOG_INFO("ipc server listening on {}, {} workers", pipe_path, thread_pool_size);
	return Status::Ok();
}

// stop 停止服务端：
//   1. 置 running_ = false
//   2. CancelIoEx current_accept_handle_，中断 acceptLoop 当前轮次的 ConnectNamedPipe
//      （无论是第几轮迭代，始终能可靠中断）
//   3. 关闭 listen_handle_（第一轮迭代兜底 + 释放资源）
//   4. CancelIoEx 所有活跃连接，中断 processConnection 中阻塞的 readFrame
//   5. 清空排队 HANDLE，推入哨兵，唤醒所有 worker
//   6. join 所有线程
void WindowsIpcServer::stop()
{
	if (!implement_->running_.exchange(false)) {
		return;
	}

	// 中断 acceptLoop 当前正在等待的 ConnectNamedPipe（任意迭代轮次均有效）
	{
		std::lock_guard<std::mutex> lk(implement_->current_accept_mutex_);
		if (implement_->current_accept_handle_ != INVALID_HANDLE_VALUE) {
			::CancelIoEx(implement_->current_accept_handle_, nullptr);
		}
	}

	// 关闭 listen_handle_（释放第一轮迭代占用的资源，或兜底第一轮 ConnectNamedPipe）
	if (implement_->listen_handle_ != INVALID_HANDLE_VALUE) {
		::CloseHandle(implement_->listen_handle_);
		implement_->listen_handle_ = INVALID_HANDLE_VALUE;
	}

	// CancelIoEx 所有活跃连接，中断 processConnection 中阻塞的 ReadFile
	{
		std::lock_guard<std::mutex> lock(implement_->active_handles_mutex_);
		for (HANDLE h : implement_->active_handles_) {
			::CancelIoEx(h, nullptr);
		}
	}

	// 清空排队 HANDLE 并推入哨兵（每个 worker 一个），唤醒所有 worker
	{
		std::lock_guard<std::mutex> lock(implement_->queue_mutex_);
		while (!implement_->work_queue_.empty()) {
			HANDLE h = implement_->work_queue_.front();
			implement_->work_queue_.pop();
			if (h != INVALID_HANDLE_VALUE) {
				::DisconnectNamedPipe(h);
				::CloseHandle(h);
			}
		}
		for (size_t i = 0; i < implement_->workers_.size(); ++i) {
			implement_->work_queue_.push(INVALID_HANDLE_VALUE);
		}
	}
	implement_->queue_cv_.notify_all();

	if (implement_->accept_thread_.joinable()) {
		implement_->accept_thread_.join();
	}
	for (auto& worker : implement_->workers_) {
		if (worker.joinable()) {
			worker.join();
		}
	}
	implement_->workers_.clear();

	LOG_INFO("ipc server stopped");
}

} // namespace ipc
} // namespace clawshell
