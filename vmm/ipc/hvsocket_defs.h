#pragma once

// hvsocket_defs.h — Hyper-V socket（AF_HYPERV）常量与结构体定义
//
// Windows 11 SDK 中的 hvsocket.h 提供这些定义；此文件在旧 SDK 版本下提供兼容声明。
// 若编译环境已包含 <hvsocket.h>，可直接使用；此处仅作为回退。

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winsock2.h>

// ── AF_HYPERV socket 地址族 ──────────────────────────────────────────────────

#ifndef AF_HYPERV
#define AF_HYPERV 34
#endif

#ifndef HV_PROTOCOL_RAW
#define HV_PROTOCOL_RAW 1
#endif

// SOCKADDR_HV — Hyper-V socket 地址结构体
//
// Family:    地址族，必须为 AF_HYPERV (34)
// Reserved:  保留字段，填 0
// VmId:      目标 VM 的 GUID；HV_GUID_WILDCARD 表示接受任意 VM
// ServiceId: 服务 GUID；对于 vsock，由端口号派生自 HV_GUID_VSOCK_TEMPLATE
#ifndef _SOCKADDR_HV_DEFINED
#define _SOCKADDR_HV_DEFINED
typedef struct _SOCKADDR_HV
{
	ADDRESS_FAMILY Family;
	USHORT         Reserved;
	GUID           VmId;
	GUID           ServiceId;
} SOCKADDR_HV;
#endif

// ── 预定义 GUID ──────────────────────────────────────────────────────────────

// HV_GUID_WILDCARD — 接受任意 VM 的通配符 GUID（全零）
// {00000000-0000-0000-0000-000000000000}
static const GUID HV_GUID_WILDCARD = {
	0x00000000, 0x0000, 0x0000,
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
};

// HV_GUID_CHILDREN — 接受来自所有子 VM（child partition）的连接
// WSL2 VM 是 Windows Root Partition 的子分区，应使用此 GUID 代替通配符
// {00000000-0000-0000-0000-000000000002}
static const GUID HV_GUID_CHILDREN = {
	0x00000000, 0x0000, 0x0000,
	{0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02}
};

// HV_GUID_VSOCK_TEMPLATE — vsock 端口到 ServiceId 的映射模板
// {00000000-facb-11e6-bd58-64006a7986d3}
// 用法：将端口号（uint32）写入 Data1 字段，其余字段不变
static const GUID HV_GUID_VSOCK_TEMPLATE = {
	0x00000000, 0xfacb, 0x11e6,
	{0xbd, 0x58, 0x64, 0x00, 0x6a, 0x79, 0x86, 0xd3}
};

// vsockPortToServiceId 将 vsock 端口号转换为 Hyper-V socket ServiceId GUID。
//
// 入参:
// - port: vsock 端口号（如 100）
//
// 出参/返回: 对应的 ServiceId GUID
inline GUID vsockPortToServiceId(uint32_t port)
{
	GUID id = HV_GUID_VSOCK_TEMPLATE;
	id.Data1 = port;
	return id;
}
