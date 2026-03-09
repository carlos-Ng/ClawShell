#pragma once

#include "common/error.h"

#include <cstdint>
#include <cstddef>
#include <string>

#ifdef _WIN32
#  include <windows.h>
#else
#  error "Platform not supported: add POSIX fd-based declarations here"
#endif

namespace clawshell {
namespace ipc {

// FrameCodec 提供基于 Length-prefix 的帧编解码功能（仅供 ipc 模块内部使用）。
//
// 帧格式：[uint32_t len（大端字节序，4 字节）][len 字节的 UTF-8 数据]
// 最大帧长：MAX_FRAME_BODY_SIZE 字节，超出视为非法，readFrame 返回错误。
constexpr size_t MAX_FRAME_BODY_SIZE = 4 * 1024 * 1024; // 4 MiB

class FrameCodec
{
public:
	// readFrame 从 Named Pipe 句柄中阻塞读取一个完整帧。
	//
	// 入参:
	// - handle: 已连接的 Named Pipe HANDLE。
	//
	// 出参/返回:
	// - Result::Ok(string)：成功，返回帧体数据（UTF-8 字符串）。
	// - Result::Error(IO_ERROR)：读取失败或对端已关闭连接。
	// - Result::Error(INVALID_ARGUMENT)：帧长超过 MAX_FRAME_BODY_SIZE。
#ifdef _WIN32
	static Result<std::string> readFrame(HANDLE handle);
#else
#  error "Platform not supported"
#endif

	// writeFrame 向 Named Pipe 句柄写入一个完整帧（含长度前缀）。
	//
	// 入参:
	// - handle: 已连接的 Named Pipe HANDLE。
	// - data:   待写入的帧体数据，长度不得超过 MAX_FRAME_BODY_SIZE。
	//
	// 出参/返回:
	// - Status::Ok()：写入成功。
	// - Status(IO_ERROR)：写入失败。
	// - Status(INVALID_ARGUMENT)：data.size() 超过 MAX_FRAME_BODY_SIZE。
#ifdef _WIN32
	static Status writeFrame(HANDLE handle, const std::string& data);
#else
#  error "Platform not supported"
#endif

private:
	// readExact 从 HANDLE 精确读取 n 字节，循环处理 ReadFile 的短读情况。
#ifdef _WIN32
	static bool readExact(HANDLE handle, void* buf, size_t n);

	// writeExact 向 HANDLE 精确写入 n 字节，循环处理 WriteFile 的短写情况。
	static bool writeExact(HANDLE handle, const void* buf, size_t n);
#else
#  error "Platform not supported"
#endif
};

} // namespace ipc
} // namespace clawshell
