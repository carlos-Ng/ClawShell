// ui_message_factory_test.cc — UIMessageFactory 单元测试
//
// UIMessageFactory 的四个静态方法是纯函数（string → JSON → string），
// 无 IO 依赖，可直接测试。

#include "ipc/ui_service.h"

#include <gtest/gtest.h>

#include <nlohmann/json.hpp>

#include <string>

namespace clawshell {
namespace ipc {
namespace {

using json = nlohmann::json;

// ── createStatus ────────────────────────────────────────────────────────────

TEST(UIMessageFactoryStatus, AgentConnectedTrue)
{
	auto msg = UIMessageFactory::createStatus(true);
	auto j = json::parse(msg);
	EXPECT_EQ(j["type"], "status");
	EXPECT_EQ(j["agent_connected"], true);
}

TEST(UIMessageFactoryStatus, AgentConnectedFalse)
{
	auto msg = UIMessageFactory::createStatus(false);
	auto j = json::parse(msg);
	EXPECT_EQ(j["type"], "status");
	EXPECT_EQ(j["agent_connected"], false);
}

// ── createTaskBegin ─────────────────────────────────────────────────────────

TEST(UIMessageFactoryTaskBegin, BasicFields)
{
	auto msg = UIMessageFactory::createTaskBegin("task-42", "user wants to edit file");
	auto j = json::parse(msg);
	EXPECT_EQ(j["type"], "task_begin");
	EXPECT_EQ(j["task_id"], "task-42");
	EXPECT_EQ(j["root_description"], "user wants to edit file");
}

TEST(UIMessageFactoryTaskBegin, EmptyDescription)
{
	auto msg = UIMessageFactory::createTaskBegin("t-1", "");
	auto j = json::parse(msg);
	EXPECT_EQ(j["type"], "task_begin");
	EXPECT_EQ(j["task_id"], "t-1");
	EXPECT_EQ(j["root_description"], "");
}

// ── createTaskEnd ───────────────────────────────────────────────────────────

TEST(UIMessageFactoryTaskEnd, BasicFields)
{
	auto msg = UIMessageFactory::createTaskEnd("task-42");
	auto j = json::parse(msg);
	EXPECT_EQ(j["type"], "task_end");
	EXPECT_EQ(j["task_id"], "task-42");
}

// ── createOpLog ─────────────────────────────────────────────────────────────

TEST(UIMessageFactoryOpLog, AllFieldsPresent)
{
	auto msg = UIMessageFactory::createOpLog(
		"task-1",
		"click",
		"allowed",
		"auto_allow",
		"clicked button OK",
		1700000000000LL
	);
	auto j = json::parse(msg);
	EXPECT_EQ(j["type"], "op_log");
	EXPECT_EQ(j["task_id"], "task-1");
	EXPECT_EQ(j["operation"], "click");
	EXPECT_EQ(j["result"], "allowed");
	EXPECT_EQ(j["source"], "auto_allow");
	EXPECT_EQ(j["detail"], "clicked button OK");
	EXPECT_EQ(j["timestamp"], 1700000000000LL);
}

TEST(UIMessageFactoryOpLog, DeniedByRule)
{
	auto msg = UIMessageFactory::createOpLog(
		"task-99",
		"exec",
		"denied",
		"rule_deny",
		"rm -rf blocked",
		1700000001000LL
	);
	auto j = json::parse(msg);
	EXPECT_EQ(j["result"], "denied");
	EXPECT_EQ(j["source"], "rule_deny");
}

TEST(UIMessageFactoryOpLog, EmptyDetail)
{
	auto msg = UIMessageFactory::createOpLog(
		"task-1", "read", "allowed", "fingerprint_cache", "", 0
	);
	auto j = json::parse(msg);
	EXPECT_EQ(j["detail"], "");
	EXPECT_EQ(j["timestamp"], 0);
}

// ── JSON 合规性（所有消息应生成有效 JSON）──────────────────────────────────

TEST(UIMessageFactoryJSON, AllMethodsProduceValidJSON)
{
	EXPECT_NO_THROW((void)json::parse(UIMessageFactory::createStatus(true)));
	EXPECT_NO_THROW((void)json::parse(UIMessageFactory::createStatus(false)));
	EXPECT_NO_THROW((void)json::parse(UIMessageFactory::createTaskBegin("t", "d")));
	EXPECT_NO_THROW((void)json::parse(UIMessageFactory::createTaskEnd("t")));
	EXPECT_NO_THROW((void)json::parse(UIMessageFactory::createOpLog("t", "o", "r", "s", "d", 0)));
}

// ── Unicode / 特殊字符 ───────────────────────────────────────────────────────

TEST(UIMessageFactoryUnicode, ChineseDescription)
{
	// MSVC C++20: u8"" produces char8_t[], use reinterpret_cast for std::string
	const char* chinese = reinterpret_cast<const char*>(u8"用户想要编辑文件");
	auto msg = UIMessageFactory::createTaskBegin("task-1", chinese);
	auto j = json::parse(msg);
	EXPECT_EQ(j["root_description"], chinese);
}

TEST(UIMessageFactoryUnicode, SpecialCharsInDetail)
{
	auto msg = UIMessageFactory::createOpLog(
		"task-1", "exec", "denied", "rule_deny",
		R"(cmd: "rm -rf /" && echo "done")", 123
	);
	auto j = json::parse(msg);
	EXPECT_EQ(j["detail"], R"(cmd: "rm -rf /" && echo "done")");
}

} // namespace
} // namespace ipc
} // namespace clawshell
