#include "frame.h"

#ifdef _WIN32
#  include <windows.h>
#else
#  error "Platform not supported: add POSIX read/write/arpa/inet.h implementation here"
#endif

namespace clawshell {
namespace ipc {

// ─── 字节序辅助 ───────────────────────────────────────────────────────────────

// hton32 / ntoh32 在没有 arpa/inet.h 的 Windows 上手动实现大端字节序转换。
static uint32_t hton32(uint32_t host)
{
	return ((host & 0x000000FFu) << 24) |
	       ((host & 0x0000FF00u) <<  8) |
	       ((host & 0x00FF0000u) >>  8) |
	       ((host & 0xFF000000u) >> 24);
}

static uint32_t ntoh32(uint32_t net)
{
	return hton32(net); // 对称操作
}

// ─── FrameCodec Windows 实现 ─────────────────────────────────────────────────

#ifdef _WIN32

// readExact 从 Named Pipe HANDLE 精确读取 n 字节，循环处理 ReadFile 的短读情况。
bool FrameCodec::readExact(HANDLE handle, void* buf, size_t n)
{
	auto*    p         = static_cast<uint8_t*>(buf);
	size_t   remaining = n;

	while (remaining > 0) {
		DWORD to_read = static_cast<DWORD>(
		    remaining > 65536 ? 65536 : remaining);
		DWORD bytes_read = 0;
		BOOL  ok         = ::ReadFile(handle, p, to_read, &bytes_read, nullptr);
		if (!ok || bytes_read == 0) {
			return false;
		}
		p         += bytes_read;
		remaining -= bytes_read;
	}
	return true;
}

// writeExact 向 Named Pipe HANDLE 精确写入 n 字节，循环处理 WriteFile 的短写情况。
bool FrameCodec::writeExact(HANDLE handle, const void* buf, size_t n)
{
	const auto* p         = static_cast<const uint8_t*>(buf);
	size_t      remaining = n;

	while (remaining > 0) {
		DWORD to_write    = static_cast<DWORD>(
		    remaining > 65536 ? 65536 : remaining);
		DWORD bytes_written = 0;
		BOOL  ok            = ::WriteFile(handle, p, to_write, &bytes_written, nullptr);
		if (!ok || bytes_written == 0) {
			return false;
		}
		p         += bytes_written;
		remaining -= bytes_written;
	}
	return true;
}

// readFrame 从 Named Pipe HANDLE 中阻塞读取一个完整帧。
Result<std::string> FrameCodec::readFrame(HANDLE handle)
{
	uint32_t net_len = 0;
	if (!readExact(handle, &net_len, sizeof(net_len))) {
		return Result<std::string>::Error(Status::IO_ERROR, "failed to read frame length");
	}
	uint32_t len = ntoh32(net_len);
	if (len == 0) {
		return Result<std::string>::Ok(std::string{});
	}
	if (len > MAX_FRAME_BODY_SIZE) {
		return Result<std::string>::Error(Status::INVALID_ARGUMENT, "frame body exceeds max size");
	}
	std::string data(len, '\0');
	if (!readExact(handle, data.data(), len)) {
		return Result<std::string>::Error(Status::IO_ERROR, "failed to read frame body");
	}
	return Result<std::string>::Ok(std::move(data));
}

// writeFrame 向 Named Pipe HANDLE 写入一个完整帧（含大端字节序的长度前缀）。
Status FrameCodec::writeFrame(HANDLE handle, const std::string& data)
{
	if (data.size() > MAX_FRAME_BODY_SIZE) {
		return Status(Status::INVALID_ARGUMENT, "frame body exceeds max size");
	}
	uint32_t net_len = hton32(static_cast<uint32_t>(data.size()));
	if (!writeExact(handle, &net_len, sizeof(net_len))) {
		return Status(Status::IO_ERROR, "failed to write frame length");
	}
	if (!data.empty() && !writeExact(handle, data.data(), data.size())) {
		return Status(Status::IO_ERROR, "failed to write frame body");
	}
	return Status::Ok();
}

#else
#  error "Platform not supported: add POSIX read/write implementation here"
#endif

} // namespace ipc
} // namespace clawshell
